defmodule Limen.Maze.Bundled do
  @moduledoc """
  The maze model of Limen's own corpus, built at compile time.

  The corpus (`priv/maze/corpus.txt`) is neutral prose that reads like the
  everyday pages of an organisation's website. Instances without a
  `:corpus` of their own use this model directly: it is a literal of this
  module, so reading it copies nothing.
  """

  alias Limen.Maze.Model

  @corpus Path.expand("../../../priv/maze/corpus.txt", __DIR__)
  @external_resource @corpus

  @text File.read!(@corpus)
  @model Model.build([@text])

  @doc """
  The text of the bundled corpus.
  """
  @spec text() :: String.t()
  def text, do: @text

  @doc """
  The model of the bundled corpus.
  """
  @spec model() :: Model.t()
  def model, do: @model
end
