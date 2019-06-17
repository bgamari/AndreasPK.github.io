import GHC.Exts

import Data.Int

import System.Environment

type IT = Int

foo :: IT -> IT -> IT -> IT
foo x y z = x + y + z

times :: Int -> [IT] -> [IT]
times n xs = concat $ replicate n xs

main = do
  print $ sum $ map (\(x,y,z) -> foo x y z) [(x,y,z) | x <- 10 `times` [0..127]
                                            , y <- 10 `times` [0..127]
                                            , z <- 1  `times` [0..127]]
