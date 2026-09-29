defmodule Limen.FormatterTest do
  use ExUnit.Case, async: true

  # Applications import Limen's formatter settings (`import_deps: [:limen]`), so
  # a DSL macro missing from the export gets parenthesised in their policies.
  test "the formatter exports every macro of the policy DSL" do
    {formatter, _binding} = Code.eval_file(Path.expand("../../.formatter.exs", __DIR__))
    exported = Keyword.fetch!(Keyword.fetch!(formatter, :export), :locals_without_parens)

    dsl = Limen.Policy.__info__(:macros) -- [__using__: 1, __before_compile__: 1]

    assert Enum.sort(exported) == Enum.sort(dsl)
  end
end
