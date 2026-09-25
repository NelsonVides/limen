defmodule Limen.Maze.ModelTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Limen.Maze.{Bundled, Model}

  @text """
  # A comment line, ignored.
  The warehouse ships pallets to the northern depot every Monday.
  The depot receives pallets from the warehouse and sorts them by route.
  Every route has a driver, a schedule and a list of stops!
  Is the schedule published on the <b>notice board</b>?
  A line without an ending
  Too short.
  """

  defp render(model, ids), do: IO.iodata_to_binary(Model.render(model, ids))

  test "reads sentences, skipping comments and very short ones" do
    assert [first | _rest] = sentences = Model.sentences(@text)
    assert first == ~w(The warehouse ships pallets to the northern depot every Monday.)
    assert length(sentences) == 5
    assert List.last(sentences) == ~w(A line without an ending.)
  end

  test "draws sentences from the corpus, escaping every word" do
    model = Model.build([@text])

    sentences =
      for seed <- 1..200 do
        {ids, _state} = Model.sentence(model, :rand.seed_s(:exsss, seed))
        render(model, ids)
      end

    assert Enum.all?(sentences, &String.ends_with?(&1, [".", "!", "?"]))
    refute Enum.any?(sentences, &String.contains?(&1, "<b>"))
    assert Enum.any?(sentences, &String.contains?(&1, "&lt;b&gt;notice"))
  end

  test "phrases are capitalised and never end on a small word" do
    model = Bundled.model()

    for seed <- 1..300 do
      {ids, _state} = Model.phrase(model, 2..6, :rand.seed_s(:exsss, seed))
      phrase = Model.render_phrase(model, ids)
      last = String.downcase(List.last(String.split(phrase, " ")))

      assert phrase =~ ~r/^[A-Z0-9]/
      refute last in ~w(the a of and to with)
      assert Model.slug(model, ids) =~ ~r/^[a-z0-9-]*$/
    end
  end

  property "every seed gives a bounded, terminated sentence" do
    model = Bundled.model()

    check all seed <- integer(1..100_000_000) do
      {ids, _state} = Model.sentence(model, :rand.seed_s(:exsss, seed))
      assert length(ids) in 1..40
      assert render(model, ids) =~ ~r/[.!?]$/
    end
  end

  test "an empty corpus cannot build a model" do
    assert_raise ArgumentError, ~r/no sentence/, fn -> Model.build(["# nothing\nToo short."]) end
  end

  test "the bundled model is built at compile time" do
    assert Model.size(Bundled.model()) > 500
    assert Bundled.model() == Model.build([Bundled.text()])
  end
end
