
#========== the macro! ==========#

"""
    @tullio C[i,k] := A[i,j] * B[j,k]
    @tullio F[i,k] := \$α * D[i].field[j] * E[col=k, row=j] + \$β

This is a replacement for `@einsum` which understands a bit more syntax.
The expression on the right is summed over all possible valued of the free index `k`,
and `:=` makes a new array `C`, while `=` and `+=` would write into an existing one.
Scalar arguments should have a dollar sign, like `\$α` or `A[i,\$γ]`.

    @tullio G[i,j] := A[i+x+1, j+y+1] * K[x,y]
    @tullio H[i,j] := A[2i+x, 2j+y]  (x in -1:1, y in -1:1)

Shifts and scaling of indices are allowed, including shifts by other indices.
Ranges can be provided as shown, for under-constrained indices.
If they are over-constrained, shifted indices run over the intersection allowed by all constraints,
while un-shifted indices demand agreement between them (e.g. `axes(A,2) == axes(B,1)` above).
OffsetArrays.jl must be loaded in order to create an array whose indices don't start at 1.

    @tullio  avx=false  threads=false  C[i,k] = A[i,j] * B[j,k]

By default it uses LoopVectorization.jl if this is loaded, and `Threads.@spawn` for big enough arrays;
the options shown disable both. Option `avx=4` will instead use `@avx unroll=4 for i in ...` loops.
Option `threads=10^3` sets the threshold at which to divide work between two threads
(in this case `10×10` matrices).

    @tullio  grad=false  C[i,k] := ...

If any of Zygote.jl/Tracker.jl/ReverseDiff.jl are loaded, then it will
define gradient hooks for these, unless disabled by `grad=false`.
The reverse gradient itself is calculated in one of two ways,
either by symbolic differentiation of the RHS (the default, `grad=Base`)
or by using dual numbers from ForwardDiff.jl (option `grad=Dual`).
You can use `Tullio.@printgrad` to show the symbolic output.

    @tullio  verbose=2

This prints out everythinng the macro knows & generates. `verbose=1` prints some information.
Options given without an expression change the global defaults, instead of applying just once.
"""
macro tullio(exs...)
    _tullio(exs...; mod=__module__)
end

function _tullio(exs...; mod=Main)

    opts, ranges, ex = parse_options(exs...)
    if isnothing(ex) # then we simply updated global settings
        return (verbose=VERBOSE[], threads=THREADS[], grad=GRAD[], avx=AVX[], cuda=CUDA[])
    end
    verbose, threads, grad, avx, cuda = opts

    store = DotDict(mod = mod, verbose = verbose,
        threads = threads, grad = grad, avx = avx, cuda = cuda,
        flags = Set{Symbol}(), # set while parsing input
    # Reduction
        redind = Symbol[],
        redfun = :+, # no way to set this just yet
    # Everything writes into leftarray[leftraw...], sometimes with a generated name
        leftraw = [],
        leftind = Symbol[],    # vcat(leftind, redind) is the complete list of loop indices
        leftarray = nothing,
        leftscalar = nothing, # only defined for scalar reduction
        leftnames = Symbol[],  # for NamedDims
    # Whole RHS, untouched, plus things extracted:
        right = nothing,
        rightind = Symbol[],
        sharedind = Symbol[],  # indices appearing on every RHS array
        arrays = Symbol[],
        scalars = Symbol[],
        cost = 1,
    # Index ranges: first save all known constraints
        constraints = Dict{Symbol,Vector}(), # :k => [:(axis(A,2)), :(axis(B,1))] etc.
        notfree = Symbol[], # indices assigned values i = clamp(j, 1,3) within RHS
        shiftedind = Symbol[],
        pairconstraints = Tuple[], # (:i, :j, entangled range_i, range_j) from A[i+j] etc.
        axisdefs = Expr[],
    # Expressions:
        outpre = Expr[],  # preliminary steps
        outex = Expr[],   # the rest!
    )

    parse_input(ex, store)

    parse_ranges(ranges, store)

    index_ranges(store)

    output_array(store)

    action_functions(store)

    verbose == 2 && verboseprint(store)

    Expr(:block, store.outpre..., store.outex...) |> esc
end

#========== options, etc ==========#

OPTS = Dict(
    :verbose => Any[true, false, 2],
    :inbounds => [true, false],
    :threads => Integer,
    :grad => [false, :Base, :Dual],
    :avx => Integer,
    :cuda => Integer,
    )

VERBOSE = Ref{Any}(false)
INBOUNDS = Ref(true)
THREADS = Ref{Any}(true)
GRAD = Ref{Any}(:Base)
AVX = Ref{Any}(true)
CUDA = Ref{Any}(256)

function parse_options(exs...)
    opts = Dict(
        :verbose => VERBOSE[],
        :threads => THREADS[],
        :grad => GRAD[],
        :avx => AVX[],
        :cuda => CUDA[],
        )
    expr = nothing
    ranges = Tuple[]
    for ex in exs
        # Actual options:
        if ex isa Expr && ex.head == :(=) && haskey(OPTS, ex.args[1])
            checklegal(ex.args[1], ex.args[2])
            opts[ex.args[1]] = ex.args[2]

        # Ranges specified outside:
        elseif ex isa Expr && ex.head == :call && ex.args[1] in [:in, :∈]
            push!(ranges, (ex.args[2], ex.args[3]))
        elseif ex isa Expr && ex.head == :tuple && ex.args[1] isa Expr && ex.args[1].args[1] in [:in, :∈]
            for el in ex.args
                el isa Expr && el.head == :call && el.args[1] in [:in, :∈] || error("expected (i ∈ 1:3) but got $el")
                push!(ranges, (el.args[2], el.args[3]))
            end

        # The main course!
        elseif ex isa Expr
            isnothing(expr) || error("too many expressions! recognised keywords are $(keys(opts))")
            expr = ex
        else
            error("not sure what to do with input $ex")
        end
    end
    if isnothing(expr) # if run with no expression, it updates global options
        VERBOSE[] = opts[:verbose]
        THREADS[] = opts[:threads]
        GRAD[] = opts[:grad]
        AVX[] = opts[:avx]
    end
    (opts[:verbose], opts[:threads], opts[:grad], opts[:avx], opts[:cuda]), ranges, expr
end

checklegal(opt, val) =
    if OPTS[opt] isa Vector
        val in OPTS[opt] || error(string("keyword $opt accepts values [" * join(OPTS[opt], ", ") * "]"))
    elseif val isa OPTS[opt]
        val >= 0 || error(string("keyword $opt accepts false or a positive integer"))
    # Silently allows val::Expr, for threads=64^3 to work
    end

verboseprint(store) = begin
    foreach(propertynames(store)) do k
        r = getproperty(store, k) # startswith(string(k), "out") fails?
        k ∉ [:outpre, :outex] && return printstyled("    $k = ", repr(r), "\n", color=:blue)
        printstyled("    $k =\n", color=:blue)
        foreach(ex -> printstyled(MacroTools_prettify(ex) , "\n", color=:green), r)
    end
end

#========== symbols ==========#

# These only need not to clash with symbols in the input:
RHS, AXIS = :𝓇𝒽𝓈, :𝒶𝓍
ZED, TYP, ACC, KEEP = :ℛ, :𝒯, :𝒜𝒸𝒸, :♻
EPS, DEL, EXPR = :𝜀, :𝛥, :ℰ𝓍

# These get defined globally, with a random number appended:
MAKE, ACT! = :𝒞𝓇ℯ𝒶𝓉ℯ, :𝒜𝒸𝓉! # :ℳ𝒶𝓀ℯ

#========== input parsing ==========#

function parse_input(expr, store)

    if @capture_(expr, left_ += right_ )
        push!(store.flags, :plusequals)
    elseif @capture_(expr, left_ := right_ )
        push!(store.flags, :newarray)
    elseif @capture_(expr, left_ = right_ )
    else error("can't understand input, expected A[] := B[], A[] = B[], or A[] += B[], got $ex")
    end

    if @capture_(left, Z_[leftraw__] ) || @capture_(left, [leftraw__] )
    elseif left isa Symbol # complete reduction, by writing into a new 0-array
        push!(store.flags, :newarray, :scalar)
        store.leftscalar = left # because store.leftarray will be the array
        leftraw = [1,] # make a 1D array, not zero
        expr.head == :(+=) && push!(store.scalars, left)
    else
        error("can't understand LHS, expected A[i,j,k], got $left")
    end
    leftraw1 = tidyleftraw(primeindices(leftraw), store)
    store.leftind = filter(i -> i isa Symbol, leftraw1) # this gives correct outer loop order
    !allunique(store.leftind) && :newarray in store.flags && push!(store.flags, :zero)

    store.leftraw = tidyleftraw2(leftraw1, store)

    isnothing(Z) && !(:newarray in store.flags) && error("can't write into an array whose name isn't given!")
    Zed = isnothing(Z) ? ZED : Z
    store.leftarray = Zed
    :newarray in store.flags || saveconstraints(Zed, leftraw, store, false) # this adds to leftind, e.g. A[2i+1] = ..., is that bad??
    :newarray in store.flags && Zed in store.arrays && error("can't create a new array $Zed when this also appears on the right")

    right1 = MacroTools_postwalk(rightwalk(store), right)
    store.right = MacroTools_postwalk(dollarwalk(store), right1)

    unique!(store.scalars)
    unique!(store.arrays)
    unique!(store.leftind)
    store.sharedind = unique!(setdiff(store.sharedind, store.notfree))
    store.rightind = unique!(setdiff(store.rightind, store.notfree))
    unique!(store.outpre) # kill mutiple assertions, and evaluate any f(A) only once

end

rightwalk(store) = ex -> begin
        @nospecialize ex
        # First, this will detect any assignment before it is used:
        if ex isa Expr && ex.head == :(=)
            if ex.args[1] isa Symbol
                push!(store.notfree, ex.args[1])
            elseif ex.args[1] isa Expr && ex.args[1].head == :tuple
                for i in ex.args[1].args
                    i isa Symbol && push!(store.notfree, i)
                end
            end
        end
        ex isa Expr && ex.head == :return && error("can't use return inside body")

        # Second, alter indexing expr. to pull out functions of arrays:
        @capture_(ex, A_[inds__]) || return ex

        if isnothing(arrayonly(A))
            Anew = Symbol(string("≪", A, "≫"))
            push!(store.outpre, :(local $Anew = $A))
            A = Anew
        end
        # Third, save letter A, and what axes(A) says about indices:
        push!(store.arrays, arrayonly(A))
        inds = primeindices(inds)
        saveconstraints(A, inds, store, true)

        # Re-assemble RHS with new A, and primes on indices taken care of.
        return :( $A[$(inds...)] )
    end # A1[i][k] should be seen later, with corrected A

arrayonly(A::Symbol) = A   # this is for RHS(i,j,k, A,B,C)
arrayonly(A::Expr) =
    if @capture_(A, B_[inds__]) || @capture_(A, B_.field_)
        return arrayonly(B)
    end # returns nothing from :(f(A)), signal to pull function out.

saveconstraints(A, inds, store, right=true) = begin
    A1 = arrayfirst(A)
    is = Symbol[]
    foreach(enumerate(inds)) do (d,ex)
        is_const(ex) && return
        containsany(ex, store.notfree) && return
        range_i, i = range_expr_walk(length(inds)==1 ? :(eachindex($A1)) : :(axes($A1,$d)), ex)
        if i isa Symbol
            push!(is, i)
            ex isa Symbol || push!(store.shiftedind, i)
            v = get!(store.constraints, i, [])
            push!(v, dollarstrip(range_i))
        elseif i isa Tuple # from things like A[i+j]
            push!(is, i...)
            push!(store.shiftedind, i...)
            push!(store.pairconstraints, (i..., dollarstrip.(range_i)...))
        end
    end
    if right
        append!(store.rightind, is)
        if isassigned(store.sharedind)
            shared = intersect(is, store.sharedind) # ?? is this right for multiple indices?
            empty!(store.sharedind)
            append!(store.sharedind, shared)
        else
            append!(store.sharedind, is)
        end
    else
        append!(store.leftind, is) # why can's this be the only path for store.leftind??
    end
    n = length(inds)
    if n==1
        str = "expected a 1-array $A1, or a tuple"
        push!(store.outpre, :( $A1 isa Tuple || ndims($A1) == 1 || error($str) ))
    else
        str = "expected a $n-array $A1" # already arrayfirst(A)
        push!(store.outpre, :( ndims($A1) == $n || error($str) ))
    end
end

arrayfirst(A::Symbol) = A  # this is for axes(A,d), axes(first(B),d), etc.
arrayfirst(A::Expr) =
    if (@capture_(A, Binds_.field_) && @capture_(Binds, B_[inds__]))
        return :( first($B).$field )
    elseif @capture_(A, B_[inds__])
        return :( first($B) )
    elseif @capture_(A, B_.field_)
        return A
    end

containsany(ex, list) = begin
    out = false
    MacroTools_postwalk(ex) do x
        if x in list
            out = true
        end
        x
    end
    out
end

primeindices(inds) = map(inds) do ex
    ex isa Expr && ex.head == Symbol("'") &&
        return Symbol(ex.args[1], "′") # normalise i''
    ex
end

dollarwalk(store) = ex -> begin
        @nospecialize ex
        ex isa Expr || return ex
        if ex.head == :call
            # ex.args[1] == :* && ex.args[2] === Int(0) && return false # tidy up dummy arrays!
            callcost(ex.args[1], store) # cost model for threading
        elseif ex.head == :$ # interpolation of $c things:
            ex.args[1] isa Symbol || error("you can only interpolate single symbols, not $ex")
            push!(store.scalars, ex.args[1])
            return ex.args[1]
        end
        ex
    end

dollarstrip(expr) = MacroTools_postwalk(expr) do @nospecialize ex
        ex isa Expr && ex.head == :$ && return ex.args[1]
        ex
    end

# there has got to be a tidier way!
tidyleftraw(leftraw, store) = map(leftraw) do i
    if i isa Expr && i.head == :kw
        if :newarray in store.flags # then NamedDims wrapper is put on later
            push!(store.leftnames, i.args[1])
            return i.args[2]
        else
            # push!(store.flags, :noavx)
        end
    elseif i === :_
        return 1
    end
    i
end
tidyleftraw2(leftraw, store) = map(leftraw) do i
    if i isa Expr && i.head == :$
        i.args[1] isa Symbol || error("you can only interpolate single symbols, not $ex")
        push!(store.scalars, i.args[1])
        return i.args[1]
    end
    i
end

function parse_ranges(ranges, store) # now runs after parse_input
    for (i,r) in ranges
        if i isa Expr && i.head == Symbol("'") # catch primes!
            i = Symbol(i.args[1], "′")
        end
        push!(store.rightind, i)
        v = get!(store.constraints, i, [])
        if r isa Expr && r.head == :call && r.args[1] == :(:) && length(r.args) == 3
            # for a literal range, write OneTo(10) or 0:9 directly into constraints
            if r.args[2] == 1 && r.args[3] isa Integer
                push!(v, :(Base.OneTo($(r.args[3]))))
                continue
            elseif r.args[2] isa Integer && r.args[3] isa Integer
                push!(v, r)
                continue
            end
        end
        # for axes(A,2) where A is already available, just save it
        if r isa Expr && r.head == :call && r.args[1] in (:axes, :eachindex) && r.args[2] in store.arrays
            push!(v, r)
            continue
        end
        # for anything else, treat it as a scalar argument
        if r isa Symbol
            push!(store.scalars, r)
            push!(v, r)
        else
            s = Symbol(string("≪", r, "≫"))
            push!(store.outpre, :($s = $r))
            push!(store.scalars, s)
            push!(v, s)
        end
    end
    unique!(store.rightind)
    store.redind = setdiff(store.rightind, store.leftind)
end

#========== index ranges ==========#

function index_ranges(store)

    todo = Set(vcat(store.leftind, store.redind))
    done = Dict{Symbol,Any}()

    for (i,j,r_i,r_j) in store.pairconstraints
        if haskey(store.constraints, i) && i in todo
            resolveintersect(i, store, done) # use existing knowledge to fix i's range
            pop!(todo, i)
            v = get!(store.constraints, j, []) # and then allow j's range to depend on that
            push!(v, r_j)
        elseif haskey(store.constraints, j) && j in todo
            resolveintersect(j, store, done)
            pop!(todo, j)
            v = get!(store.constraints, i, [])
            push!(v, r_i)
        end
    end

    for i in todo
        haskey(store.constraints, i) || error("unable to infer range of index $i")
        if i in store.shiftedind
            resolveintersect(i, store, done)
        else
            resolvestrict(i, store, done)
        end
    end

    append!(store.outex, store.axisdefs)

    if store.verbose > 0
        lex = map(i -> Expr(:(=), i, done[i]), store.leftind)
        push!(store.outex, :(@info "left index ranges" $(lex...)))
        if !isempty(store.redind)
            rex = map(i -> Expr(:(=), i, done[i]), store.redind)
            push!(store.outex, :(@info "reduction index ranges" $(rex...)))
        end
    end
end

resolvestrict(i, store, done) = begin
    res = first(store.constraints[i])
    ax_i = Symbol(AXIS, i)
    push!(store.axisdefs, :( local $ax_i = $res ))
    done[i] = res
    for alt in store.constraints[i][2:end] # in which case it shouldn't be a Set
        str = "range of index $i must agree"
        push!(store.axisdefs, :( $alt == $res || error($str) ))
    end
end

resolveintersect(i, store, done) = begin
    res = length(store.constraints[i])==1 ?
        first(store.constraints[i]) : # because intersect(1:3) isa Vector, wtf?
        :( intersect($(store.constraints[i]...)) )
    ax_i = Symbol(AXIS, i)
    push!(store.axisdefs, :( local $ax_i = $res ))
    done[i] = res
end

#========== output array + eltype ==========#

function output_array(store)
    if :newarray in store.flags

        push!(store.outex, :( local $RHS($(store.arrays...), $(store.rightind...)) = $(store.right) ))

        # Try inference first, usually fine, and avoids scalar evaluation on GPU
        allfirst = map(i -> :(first($(Symbol(AXIS, i)))), store.rightind)
        T0 = Symbol(TYP,0)
        str = "unable to infer eltype from RHS = $(store.right)"
        push!(store.outex, quote
            local $T0 = Core.Compiler.return_type($RHS, typeof(($(store.arrays...), $(allfirst...))))
            local $TYP = if Base.isconcretetype($T0)
                $T0
            else
                @debug $str
                typeof($RHS($(store.arrays...), $(allfirst...)))
            end
        end)

        # This now checks for OffsetArrays, and allows A[i,1] := ...
        outaxes = map(store.leftraw) do i
            i isa Integer && i==1 && return :(Base.OneTo(1))
            i isa Symbol && return Symbol(AXIS, i)
            error("can't use index $i on LHS for a new array")
        end

        if !isdefined(store.mod, :OffsetArrays)
            outaxes = map(store.leftraw, outaxes) do i, ax
                ax == :(Base.OneTo(1)) && return ax
                i in store.shiftedind || return ax
                push!(store.outex, :( first($ax) == 1 || error("to allow indices not starting at 1, OffsetArrays must be visible in the caller's module")))
                return :(Base.OneTo($ax))
            end
        end

        simex = if isempty(store.arrays)
            # :( zeros($TYP, tuple($(outaxes...))) ) # Array{T} doesn't accept ranges... but zero() doesn't accept things like  @tullio [i,j] := (i,j)  i ∈ 2:3, j ∈ 4:5
            :( similar([], $TYP, tuple($(outaxes...))) )
        else
            :( similar($(store.arrays[1]), $TYP, tuple($(outaxes...),)) )
        end
        if isempty(store.leftnames)
            push!(store.outex, :( local $(store.leftarray) = $simex ))
        else
            nex = :(tuple($(QuoteNode.(store.leftnames)...)))
            push!(store.outex, :( local $(store.leftarray) = NamedDims.NamedDimsArray($simex, $nex) ))
        end

        # Deal with scalar += now: write into array, later read it out:
        if :scalar in store.flags && :plusequals in store.flags
            push!(store.outex, :($(store.leftarray)[$(store.leftraw...)] = $(store.leftscalar)))
        end
    end

    if :zero in store.flags
        push!(store.outex, :( $(store.leftarray) .= zero($TYP) ))
    end

end

#========== action functions ==========#

function action_functions(store)

    rn = abs(rand(Int16))
    act!, make = Symbol(ACT!, rn), Symbol(MAKE, rn)

    axisleft = map(i -> Symbol(AXIS, i), store.leftind)
    axisred = map(i -> Symbol(AXIS, i), store.redind)
    axislist = vcat(axisleft, axisred)

    #===== constructing loops =====#

    init = store.redfun == :* ? :(one($TYP)) :
        store.redfun == :max ? :(typemin($TYP)) :
        store.redfun == :min ? :(typemin($TYP)) :
        :(zero($TYP))

    # Right now this would allow *= only with reduction * too. Could separate them:
    # acc=0; acc = acc + rhs; Z[i] = ifelse(keep, acc, Z[i] * acc)
    # But then keep=true can't be used for blocking, which wants to continue the same as acc.

    ex_init = :( $ACC = ifelse($KEEP === nothing, $init, $ZED[$(store.leftraw...)]) )
    # ex_init = :( $ACC = $KEEP === nothing ? $init : $ZED[$(store.leftraw...)] ) # both OK, ifelse is tidier!

    ex_iter = :( $ACC = $(store.redfun)($ACC, $(store.right) ) )

    ex_write = :( $ZED[$(store.leftraw...)] = $ACC )

    ex_nored = :(
        $ZED[$(store.leftraw...)] = $KEEP === nothing ?
        $(store.right) :
        $(store.redfun)($ZED[$(store.leftraw...)] ,$(store.right))
        )

    if isempty(store.redind)
        make_many_actors(act!,
            vcat(:($ZED::AbstractArray{$TYP}), store.arrays, store.scalars, axislist),
            nothing, store.leftind, nothing, Symbol[], ex_nored, nothing, store)
    else
        make_many_actors(act!,
            vcat(:($ZED::AbstractArray{$TYP}), store.arrays, store.scalars, axislist),
            nothing, store.leftind, ex_init, store.redind, ex_iter, ex_write, store)
    end

    # make_many_actors and backward_definitions both push into store.outpre
    ∇make = backward_definitions(make, act!, store)

    #===== action! =====#

    ST = :($storage_type($(store.leftarray), $(store.arrays...)))
    keep = (:plusequals in store.flags) ? :true : :nothing
    block = store.threads==false ? nothing :
        store.threads==true ? (BLOCK[] ÷ store.cost) :
        store.threads
    push!(store.outex, quote
        $threader($act!, $ST, $(store.leftarray),
            tuple($(store.arrays...), $(store.scalars...),),
            tuple($(axisleft...),), tuple($(axisred...),);
            block = $block, keep = $keep)
        $(store.leftarray)
    end)

    if :newarray in store.flags
        # then slurp up outex to make a function:
        sofar = Expr(:block, store.outex...)
        empty!(store.outex)
        ex = quote
            let $act! = $act!
                function $make($(store.arrays...), $(store.scalars...), )
                    $sofar
                end
                $Eval($make, $∇make)($(store.arrays...), $(store.scalars...), )
            end
        end
        # and assign the result if necc:
        if store.leftarray != ZED
            push!(store.outex, :($(store.leftarray) = $ex ))
        elseif :scalar in store.flags
             push!(store.outex, :($(store.leftscalar) = sum($ex)))
        else # case of [i,j] := ... with no name given
            push!(store.outex, ex)
        end
    end
end


"""
    make_many_actors(f!, args, ex1, [:i,], ex3, [:k,], ex5, ex6, store)

This makes several functions of this form,
decorated as necessary with `@inbouds` or `@avx` etc,
and with appropriate `storage_type` as the first argument.
```
f!(::Type, args..., keep=nothing) where {T}
    ex1
    ex2 = (for i in axis_i
        ex3
        ex4 = (for k in axis_k
            ex5
        end)
        ex6
    end)
end
```
"""
function make_many_actors(act!, args, ex1, outer::Vector, ex3, inner::Vector, ex5, ex6, store, note="")

    ex4 = recurseloops(ex5, inner)
    ex2 = recurseloops(:($ex3; $ex4; $ex6), outer)

    if isempty(store.notfree)
        push!(store.outpre, quote
            local function $act!(::Type, $(args...), $KEEP=nothing) where {$TYP}
                @inbounds @fastmath ($ex1; $ex2)
            end
        end)
    else
        push!(store.outpre, quote
            local function $act!(::Type, $(args...), $KEEP=nothing) where {$TYP}
                ($ex1; $ex2)
            end
        end)
    end

    expre, exloop, expost = if isempty(outer)
        :($ex1; $ex3), ex4, ex6
    else
        ex1, ex2, nothing
    end

    if store.avx != false && isdefined(store.mod, :LoopVectorization)
        unroll = store.avx == true ? 0 : store.avx # unroll=0 is the default setting
        try lex = macroexpand(store.mod, quote

                local function $act!(::Type{<:Array{<:Union{Base.HWReal, Bool}}}, $(args...), $KEEP=nothing) where {$TYP}
                    $expre
                    LoopVectorization.@avx unroll=$unroll $exloop
                    $expost
                end

            end) # quote
            push!(store.outpre, lex)
            store.verbose == 2 && @info "success wtih LoopVectorization, unroll=$unroll $note"
        catch err
            store.verbose > 0 && @error "LoopVectorization failed $note" err
        end
    end

    axouter = map(i -> Symbol(AXIS, i), outer)

    if store.cuda > 0 &&
        isdefined(store.mod, :KernelAbstractions) &&
        isdefined(store.mod, :CuArrays)

        kernel = Symbol(act!, :🇨🇺)
        asserts = map(ax -> :( first($ax)==1 || error("KernelAbstractions can't handle OffsetArrays here")), axouter)
        sizes = map(ax -> :(length($ax)), axouter)
        try kex1 = macroexpand(store.mod, quote

                KernelAbstractions.@kernel function $kernel($(args...), $KEEP) where {$TYP}
                    ($(outer...),) = @index(Global, NTuple)
                    ($ex1; $ex3; $ex4; $ex6)
                end

            end)
            kex2 = quote

                local function $act!(::Type{<:CuArray}, $(args...), $KEEP=nothing) where {$TYP}
                    @debug "KernelAbstractions CuArrays actor"
                    cu_kern! = $kernel(CUDA(), $(store.cuda))
                    $(asserts...)
                    $ACC = cu_kern!($(args...), $KEEP; ndrange=tuple($(sizes...)))
                    KernelAbstractions.wait($ACC)
                end

                # For testing, this probably wants threads=false
                # Less specific than LoopVectorization signature
                local function $act!(::Type{<:Array}, $(args...), $KEEP=nothing) where {$TYP}
                    @debug "KernelAbstractions CPU actor:" typeof.(tuple($(args...)))
                    cpu_kern! = $kernel(CPU(), Threads.nthreads())
                    $(asserts...)
                    $ACC = cpu_kern!($(args...), $KEEP; ndrange=tuple($(sizes...)))
                    KernelAbstractions.wait($ACC)
                end

            end
            push!(store.outpre, kex1, kex2)
            store.verbose == 2 && @info "success wtih KernelAbstractions $note"
        catch err
            store.verbose > 0 && @error "KernelAbstractions failed $note" err
        end
    end
end


recurseloops(ex, list::Vector) =
    if isempty(list)
        return ex
    else
        i = first(list)
        r = Symbol(AXIS, i)
        ex = :(for $i in $r; $ex; end)
        return recurseloops(ex, list[2:end])
    end

#===== define gradient hooks =====#

function backward_definitions(make, act!, store)
    store.grad == false && return nothing # no gradient wanted

    ok = false
    if store.grad == :Dual
        isdefined(store.mod, :ForwardDiff) || error("grad=Dual can only be used when ForwardDiff is visible")
        insert_forward_gradient(act!, store)
        ok = true
        store.verbose == 2 && @info "using ForwardDiff gradient"
    elseif store.grad == :Base
        try
            insert_symbolic_gradient(act!, store)
            ok = true
            store.verbose == 2 && @info "success wtih Symbolic gradient"
        catch err
            store.verbose > 0 && @error "Symbolic gradient failed" err
        end
    end

    ok == false && return nothing # failed to make a gradient

    dZ = Symbol(DEL, ZED)
    ∇make = Symbol(:∇, make)
    ∇act! = Symbol(:∇, act!)

    gradarrays = map(A -> Symbol(DEL, A), store.arrays)
    # gradscalars = map(A -> Symbol(DEL, A), store.scalars)
    defineempties = map(store.arrays, gradarrays) do A, dA
        :( $dA = fill!(similar($A, Base.promote_type(eltype($A), $TYP)), 0) )
    end
    # append!(defineempties, map((x,dx) -> :($dx = zero(Base.promote_type(typeof($x), $TYP))), store.scalars, gradscalars))
    returns = vcat(gradarrays, map(_->:nothing, store.scalars)) # ?? needs a test!
    # returns = vcat(gradarrays, gradscalars)

    loopind = vcat(store.leftind, store.redind)
    # "sharedind" go first in argument list, they are safe to thread over
    shared = map(i -> Symbol(AXIS, i), store.sharedind)
    nonshared = map(i -> Symbol(AXIS, i), setdiff(loopind, store.sharedind))

    ST = :($storage_type($(gradarrays...), $(store.arrays...)))
    block = store.threads==false ? nothing :
        store.threads==true ? (BLOCK[] ÷ store.cost) :
        store.threads
    push!(store.outpre, quote

        local function $∇make($dZ::AbstractArray{$TYP}, $(store.arrays...), $(store.scalars...), ) where {$TYP}
            $(defineempties...)
            $(store.axisdefs...)
            $∇threader($∇act!, $ST,
                tuple($(gradarrays...), $dZ, $(store.arrays...), $(store.scalars...),),
                tuple($(shared...),), tuple($(nonshared...), );
                block = $block)
            return ($(returns...),)
        end

    end)

    return ∇make
end

fillarrayreplace(rhs, dZ) = MacroTools_postwalk(rhs) do @nospecialize ex
        @capture_(ex, A_[inds__]) && A==dZ || return ex
        return Symbol(dZ, :_value)
    end

#========== the end ==========#
