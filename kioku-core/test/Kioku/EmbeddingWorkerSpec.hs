module Kioku.EmbeddingWorkerSpec
  ( tests,
  )
where

import Kioku.Memory.Embedding.Worker (shouldSkipEmbedding)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Embedding worker"
    [ testCase "skips only when the embedding exists and the content hash matches" do
        shouldSkipEmbedding True (Just "hash-a") "hash-a" @?= True
        shouldSkipEmbedding False (Just "hash-a") "hash-a" @?= False
        shouldSkipEmbedding True Nothing "hash-a" @?= False
        shouldSkipEmbedding True (Just "hash-b") "hash-a" @?= False
    ]
