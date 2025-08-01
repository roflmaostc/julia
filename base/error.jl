# This file is a part of Julia. License is MIT: https://julialang.org/license

# pseudo-definitions to show how everything behaves
#
# throw(label, val) = # throw a value to a dynamically enclosing block
#
# function rethrow(val)
#     global current_exception = val
#     throw(current_handler(), current_exception)
# end
#
# rethrow() = rethrow(current_exception)
#
# function throw(val)
#     global catch_backtrace = backtrace()
#     rethrow(val)
# end

"""
    throw(e)

Throw an object as an exception.

See also: [`rethrow`](@ref), [`error`](@ref).
"""
throw

## native julia error handling ##

# This is `Experimental.@max_methods 2 function error end`, which is not available at this point in bootstrap.
# NOTE It is important to always be able to infer the return type of `error` as `Union{}`,
# but there's a hitch when a package globally sets `@max_methods 1` and it causes inference
# for `error(::Any)` to fail (JuliaLang/julia#54029).
# This definition site `@max_methods 2` setting overrides any global `@max_methods 1` settings
# on package side, guaranteeing that return type inference on `error` is successful always.
function error end
typeof(error).name.max_methods = UInt8(2)

"""
    error(message::AbstractString)

Raise an `ErrorException` with the given message.
"""
error(s::AbstractString) = throw(ErrorException(s))
error() = throw(ErrorException(""))

"""
    error(msg...)

Raise an `ErrorException` with a message constructed by `string(msg...)`.
"""
function error(s::Vararg{Any,N}) where {N}
    @noinline
    throw(ErrorException(Main.Base.string(s...)))
end

"""
    rethrow()

Rethrow the current exception from within a `catch` block. The rethrown
exception will continue propagation as if it had not been caught.

!!! note
    The alternative form `rethrow(e)` allows you to associate an alternative
    exception object `e` with the current backtrace. However this misrepresents
    the program state at the time of the error so you're encouraged to instead
    throw a new exception using `throw(e)`. In Julia 1.1 and above, using
    `throw(e)` will preserve the root cause exception on the stack, as
    described in [`current_exceptions`](@ref).
"""
rethrow() = ccall(:jl_rethrow, Bottom, ())
rethrow(@nospecialize(e)) = ccall(:jl_rethrow_other, Bottom, (Any,), e)

struct InterpreterIP
    code::Union{CodeInfo,Core.MethodInstance,Core.CodeInstance,Nothing}
    stmt::Csize_t
    mod::Union{Module,Nothing}
end

# convert dual arrays (raw bt buffer, array of GC managed values) to a single
# array of locations
function _reformat_bt(bt::Array{Ptr{Cvoid},1}, bt2::Array{Any,1})
    ret = Vector{Union{InterpreterIP,Ptr{Cvoid}}}()
    i, j = 1, 1
    while i <= length(bt)
        ip = bt[i]::Ptr{Cvoid}
        if UInt(ip) != (-1 % UInt) # See also jl_bt_is_native
            # native frame
            push!(ret, ip)
            i += 1
            continue
        end
        # Extended backtrace entry
        entry_metadata = reinterpret(UInt, bt[i+1])::UInt
        njlvalues =  entry_metadata & 0x7
        nuintvals = (entry_metadata >> 3) & 0x7
        tag       = (entry_metadata >> 6) & 0xf
        header    =  entry_metadata >> 10
        if tag == 1 # JL_BT_INTERP_FRAME_TAG
            code = bt2[j]::Union{CodeInfo,Core.MethodInstance,Core.CodeInstance,Nothing}
            mod = njlvalues == 2 ? bt2[j+1]::Union{Module,Nothing} : nothing
            push!(ret, InterpreterIP(code, header, mod))
        else
            # Tags we don't know about are an error
            throw(ArgumentError("Unexpected extended backtrace entry tag $tag at bt[$i]"))
        end
        # See jl_bt_entry_size
        j += Int(njlvalues)
        i += 2 + Int(njlvalues + nuintvals)
    end
    ret
end

"""
    backtrace()

Get a backtrace object for the current program point.
"""
function backtrace()
    @noinline
    # skip frame for backtrace(). Note that for this to work properly,
    # backtrace() itself must not be interpreted nor inlined.
    skip = 1
    bt1, bt2 = ccall(:jl_backtrace_from_here, Ref{SimpleVector}, (Cint, Cint), false, skip)
    return _reformat_bt(bt1::Vector{Ptr{Cvoid}}, bt2::Vector{Any})
end

"""
    catch_backtrace()

Get the backtrace of the current exception, for use within `catch` blocks.
"""
function catch_backtrace()
    bt, bt2 = ccall(:jl_get_backtrace, Ref{SimpleVector}, ())
    return _reformat_bt(bt::Vector{Ptr{Cvoid}}, bt2::Vector{Any})
end

struct ExceptionStack <: AbstractArray{NamedTuple{(:exception, :backtrace)},1}
    stack::Array{NamedTuple{(:exception, :backtrace)},1}
end

"""
    current_exceptions(task::Task=current_task(); [backtrace::Bool=true])

Get the stack of exceptions currently being handled. For nested catch blocks
there may be more than one current exception in which case the most recently
thrown exception is last in the stack. The stack is returned as an
`ExceptionStack` which is an AbstractVector of named tuples
`(exception,backtrace)`. If `backtrace` is false, the backtrace in each pair
will be set to `nothing`.

Explicitly passing `task` will return the current exception stack on an
arbitrary task. This is useful for inspecting tasks which have failed due to
uncaught exceptions.

!!! compat "Julia 1.7"
    This function went by the experimental name `catch_stack()` in Julia
    1.1–1.6, and had a plain Vector-of-tuples as a return type.
"""
function current_exceptions(task::Task=current_task(); backtrace::Bool=true)
    raw = ccall(:jl_get_excstack, Any, (Any,Cint,Cint), task, backtrace, typemax(Cint))::Vector{Any}
    formatted = NamedTuple{(:exception, :backtrace)}[]
    stride = backtrace ? 3 : 1
    for i = reverse(1:stride:length(raw))
        exc = raw[i]
        bt = backtrace ? Base._reformat_bt(raw[i+1],raw[i+2]) : nothing
        push!(formatted, (exception=exc,backtrace=bt))
    end
    ExceptionStack(formatted)
end

## keyword arg lowering generates calls to this ##
function kwerr(kw, args::Vararg{Any,N}) where {N}
    @noinline
    throw(MethodError(Core.kwcall, (kw, args...), tls_world_age()))
end

## system error handling ##
"""
    systemerror(sysfunc[, errno::Cint=Libc.errno()])
    systemerror(sysfunc, iftrue::Bool)

Raises a `SystemError` for `errno` with the descriptive string `sysfunc` if `iftrue` is `true`
"""
systemerror(p, b::Bool; extrainfo=nothing) = b ? systemerror(p, extrainfo=extrainfo) : nothing
systemerror(p, errno::Cint=Libc.errno(); extrainfo=nothing) = throw(Main.Base.SystemError(string(p), errno, extrainfo))

## system errors from Windows API functions
struct WindowsErrorInfo
    errnum::UInt32
    extrainfo
end
"""
    windowserror(sysfunc[, code::UInt32=Libc.GetLastError()])
    windowserror(sysfunc, iftrue::Bool)

Like [`systemerror`](@ref), but for Windows API functions that use [`GetLastError`](@ref Base.Libc.GetLastError) to
return an error code instead of setting [`errno`](@ref Base.Libc.errno).
"""
windowserror(p, b::Bool; extrainfo=nothing) = b ? windowserror(p, extrainfo=extrainfo) : nothing
windowserror(p, code::UInt32=Libc.GetLastError(); extrainfo=nothing) = throw(Main.Base.SystemError(string(p), 0, WindowsErrorInfo(code, extrainfo)))


## assertion macro ##


"""
    @assert cond [text]

Throw an [`AssertionError`](@ref) if `cond` is `false`. This is the preferred syntax for
writing assertions, which are conditions that are assumed to be true, but that the user
might decide to check anyways, as an aid to debugging if they fail.
The optional message `text` is displayed upon assertion failure.

!!! warning
    An assert might be disabled at some optimization levels.
    Assert should therefore only be used as a debugging tool
    and not used for authentication verification (e.g., verifying passwords or checking array bounds).
    The code must not rely on the side effects of running `cond` for the correct behavior
    of a function.

# Examples
```jldoctest
julia> @assert iseven(3) "3 is an odd number!"
ERROR: AssertionError: 3 is an odd number!

julia> @assert isodd(3) "What even are numbers?"
```
"""
macro assert(ex, msgs...)
    msg = isempty(msgs) ? ex : msgs[1]
    if isa(msg, AbstractString)
        msg = msg # pass-through
    elseif !isempty(msgs) && (isa(msg, Expr) || isa(msg, Symbol))
        # message is an expression needing evaluating
        # N.B. To reduce the risk of invalidation caused by the complex callstack involved
        # with `string`, use `inferencebarrier` here to hide this `string` from the compiler.
        msg = :(Main.Base.inferencebarrier(Main.Base.string)($(esc(msg))))
    elseif isdefined(Main, :Base) && isdefined(Main.Base, :string) && applicable(Main.Base.string, msg)
        msg = Main.Base.string(msg)
    else
        # string() might not be defined during bootstrap
        msg = :(_assert_tostring($(Expr(:quote,msg))))
    end
    return :($(esc(ex)) ? $(nothing) : throw(AssertionError($msg)))
end

# this may be overridden in contexts where `string(::Expr)` doesn't work
_assert_tostring(@nospecialize(msg)) = Core.compilerbarrier(:type, __assert_tostring)(msg)
__assert_tostring(msg) = isdefined(Main, :Base) ? Main.Base.string(msg) :
    (Core.println(msg); "Error during bootstrap. See stdout.")

struct ExponentialBackOff
    n::Int
    first_delay::Float64
    max_delay::Float64
    factor::Float64
    jitter::Float64

    function ExponentialBackOff(n, first_delay, max_delay, factor, jitter)
        all(x->x>=0, (n, first_delay, max_delay, factor, jitter)) || error("all inputs must be non-negative")
        new(n, first_delay, max_delay, factor, jitter)
    end
end

"""
    ExponentialBackOff(; n=1, first_delay=0.05, max_delay=10.0, factor=5.0, jitter=0.1)

A [`Float64`](@ref) iterator of length `n` whose elements exponentially increase at a
rate in the interval `factor` * (1 ± `jitter`).  The first element is
`first_delay` and all elements are clamped to `max_delay`.
"""
ExponentialBackOff(; n=1, first_delay=0.05, max_delay=10.0, factor=5.0, jitter=0.1) =
    ExponentialBackOff(n, first_delay, max_delay, factor, jitter)
function iterate(ebo::ExponentialBackOff, state= (ebo.n, min(ebo.first_delay, ebo.max_delay)))
    state[1] < 1 && return nothing
    next_n = state[1]-1
    curr_delay = state[2]
    next_delay = min(ebo.max_delay, state[2] * ebo.factor * (1.0 - ebo.jitter + (Libc.rand(Float64) * 2.0 * ebo.jitter)))
    (curr_delay, (next_n, next_delay))
end
length(ebo::ExponentialBackOff) = ebo.n
eltype(::Type{ExponentialBackOff}) = Float64

"""
    retry(f;  delays=ExponentialBackOff(), check=nothing) -> Function

Return an anonymous function that calls function `f`.  If an exception arises,
`f` is repeatedly called again, each time `check` returns `true`, after waiting the
number of seconds specified in `delays`.  `check` should input `delays`'s
current state and the `Exception`.

!!! compat "Julia 1.2"
    Before Julia 1.2 this signature was restricted to `f::Function`.

# Examples
```julia
retry(f, delays=fill(5.0, 3))
retry(f, delays=rand(5:10, 2))
retry(f, delays=Base.ExponentialBackOff(n=3, first_delay=5, max_delay=1000))
retry(http_get, check=(s,e)->e.status == "503")(url)
retry(read, check=(s,e)->isa(e, IOError))(io, 128; all=false)
```
"""
function retry(f;  delays=ExponentialBackOff(), check=nothing)
    (args...; kwargs...) -> begin
        y = iterate(delays)
        while y !== nothing
            (delay, state) = y
            try
                return f(args...; kwargs...)
            catch e
                if check !== nothing
                    result = check(state, e)
                    state, retry_or_not = length(result) == 2 ? result : (state, result)
                    retry_or_not || rethrow()
                end
            end
            sleep(delay)
            y = iterate(delays, state)
        end
        # When delays is out, just run the function without try/catch
        return f(args...; kwargs...)
    end
end
