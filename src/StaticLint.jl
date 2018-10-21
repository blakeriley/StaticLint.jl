module StaticLint
using CSTParser, SymbolServer

const Index = Tuple
struct SIndex{N}
    i::NTuple{N,Int}
    n::Int
end

mutable struct Location
    file::String
    offset::Int
end

mutable struct Reference{T}
    val::T
    loc::Location
    si::SIndex
    delayed::Bool
end

include("bindings.jl")

mutable struct ResolvedRef{T, S}
    r::Reference{T}
    b::S
end

mutable struct Include{T}
    val::T
    file::String
    offset::Int
    index::Index
    pos::Int
end

mutable struct Scope
    parent::Union{Nothing,Scope}
    children::Vector{Scope}
    offset::UnitRange{Int}
    t::DataType
    index::Index
    bindings::Int
end
Scope() = Scope(nothing, [], 0:-1, CSTParser.TopLevel, (), 0)

mutable struct State
    loc::Location
    bindings
    modules::Vector{Binding}
    exports::Dict{Tuple,Vector{String}}
    imports::Vector{ImportBinding}
    used_modules::Dict{String,Binding}
    refs::Vector{Reference}
    includes::Vector{Include}
    server
end
State() = State(Location("", 0), Dict{Tuple,Any}(), Binding[], Dict{Tuple,Vector}(),ImportBinding[], Dict{String,Binding}(), Reference[], Include[], DocumentServer())
State(path::String, server) = State(Location(path, 0), Dict{Tuple,Any}(), Binding[], Dict{Tuple,Vector}(),ImportBinding[], Dict{String,Binding}(), Reference[], Include[], server)

mutable struct File
    cst::CSTParser.EXPR
    state::State
    scope::Scope
    index::Index
    nb::Int
    parent::String
    rref::Vector{ResolvedRef}
    uref::Vector{Reference}
end
File(x::CSTParser.EXPR) = File(x, State(), Scope(), (), 0, "", [], [])
File(x::CSTParser.EXPR, pkgs::Dict) = File(x, State("", DocumentServer(Dict(), pkgs)), Scope(), (), 0, "", [], [])

function pass(x::CSTParser.LeafNode, state::State, s::Scope, index, blockref, delayed)
    state.loc.offset += x.fullspan
end

function pass(x, state::State, s::Scope, index, blockref, delayed)
    if x isa CSTParser.BinarySyntaxOpCall && x.op.kind == CSTParser.Tokenize.Tokens.EQ && !(CSTParser.defines_function(x) || (x isa CSTParser.BinarySyntaxOpCall && x.op.kind == CSTParser.Tokens.EQ && x.arg1 isa CSTParser.EXPR{CSTParser.Curly}))
        # do rhs first
        offset = state.loc.offset
        state.loc.offset += x.arg1.fullspan
        ablockref = get_ref(x.op, state, s, blockref, delayed)
        pass(x.op, state, s, s.index, ablockref, delayed)
        ablockref = get_ref(x.arg2, state, s, blockref, delayed)
        pass(x.arg2, state, s, s.index, ablockref, delayed)

        state.loc.offset = offset
        ext_binding(x, state, s) # Get external bindings generated by `x`.
        s1 = create_scope(x, state, s) # Create new scope (if needed) for traversing through `x`.
        ablockref = get_ref(x.arg1, state, s1, blockref, delayed)
        pass(x.arg1, state, s1, s1.index, ablockref, delayed)
        state.loc.offset += x.op.fullspan + x.arg2.fullspan
    elseif x isa CSTParser.BinarySyntaxOpCall && x.op.kind == CSTParser.Tokens.DECLARATION
        ablockref = get_ref(x.arg1, state, s, blockref, delayed)
        pass(x.arg1, state, s, s.index, ablockref, delayed)

        ablockref = get_ref(x.op, state, s, blockref, delayed)
        pass(x.op, state, s, s.index, ablockref, delayed)
        
        delayed = false
        ablockref = get_ref(x.arg2, state, s, blockref, delayed)
        pass(x.arg2, state, s, s.index, ablockref, delayed)
    else
        ext_binding(x, state, s) # Get external bindings generated by `x`.
        s1 = create_scope(x, state, s) # Create new scope (if needed) for traversing through `x`.
        delayed = delayed || s1.t == CSTParser.FunctionDef || x isa CSTParser.EXPR{CSTParser.Export} # Internal scope evaluation is delayed
        # if delayed && (x isa CSTParser.BinarySyntaxOpCall && x.op.kind == CSTParser.Tokens.DECLARATION)
        #     delayed = false
        # end
        get_include(x, state, s1) # Check whether `x` includes a file.
        for a in x # Traverse sub expressions of `x`.
            ablockref = get_ref(a, state, s1, blockref, delayed)
            pass(a, state, s1, s1.index, ablockref, delayed)
        end
    end
    s
end

function pass(x::CSTParser.EXPR{CSTParser.Kw}, state::State, s::Scope, index, blockref, delayed)
    if x.args[1] isa CSTParser.IDENTIFIER
        state.loc.offset += x.args[1].fullspan + x.args[2].fullspan
        pass(x.args[3], state, s, s.index, blockref, delayed)
    else
        for a in x
            ablockref = get_ref(a, state, s, blockref, delayed)
            pass(a, state, s, s.index, ablockref, delayed)
        end
        s
    end        
end

function pass(x::CSTParser.EXPR{CSTParser.Try}, state::State, s::Scope, index, blockref, delayed)
    s1 = create_scope(x, state, s)
    it = 1
    for a in x
        if it == 4 && a isa CSTParser.IDENTIFIER
            add_binding(CSTParser.str_value(a), a, state, s1)
        end
        ablockref = get_ref(a, state, s1, blockref, delayed)
        pass(a, state, s1, s1.index, ablockref, delayed)
        it += 1
    end
end

function pass(file::File)
    file.state.loc.offset = 0
    empty!(file.state.refs)
    empty!(file.state.includes)
    empty!(file.state.bindings)
    empty!(file.state.modules)
    empty!(file.state.imports)
    empty!(file.state.exports)
    empty!(file.state.used_modules)
    file.scope = Scope(nothing, Scope[], file.cst.span, CSTParser.TopLevel, file.index, file.nb)
    file.scope = pass(file.cst, file.state, file.scope, file.index, false, false)
end

include("references.jl")
include("utils.jl")
include("documentserver.jl")
include("helpers.jl")
include("infer.jl")
include("display.jl")


const _Module   = SymbolServer.corepackages["Core"]["Module"]
const _DataType = SymbolServer.corepackages["Core"]["DataType"]
const _Function = SymbolServer.corepackages["Core"]["Function"]

end
