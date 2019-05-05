data Shape = Rock | Paper | Scissors deriving Eq

play Paper Rock = "Paper wins"
play Paper Scissors = "Scissors wins"
play Rock Scissors = "Rock Wins"
play  x y | x == y = "Tie"
          | otherwise = play y x



-- abstract type Shape end
-- struct Rock     <: Shape end
-- struct Paper    <: Shape end
-- struct Scissors <: Shape end
-- play(::Type{Paper}, ::Type{Rock})     = "Paper wins"
-- play(::Type{Paper}, ::Type{Scissors}) = "Scissors wins"
-- play(::Type{Rock},  ::Type{Scissors}) = "Rock wins"
-- play(::Type{T},     ::Type{T}) where {T<: Shape} = "Tie, try again"
-- play(a::Type{<:Shape}, b::Type{<:Shape}) = play(b, a) # Commutativity