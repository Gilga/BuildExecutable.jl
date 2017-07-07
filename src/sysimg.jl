using Base
importall Base.Operators

Base.isfile("userimg.jl") && Base.include("userimg.jl")
