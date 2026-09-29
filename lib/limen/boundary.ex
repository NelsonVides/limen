defmodule Limen.Boundary do
  @moduledoc false
  # Limen declares its layers with the `boundary` library, whose compiler
  # checks them in Limen's own builds. Applications compile Limen as a
  # dependency, without that compiler, so they need not depend on `boundary`
  # at all: `use Limen.Boundary` declares a boundary only when the compiler
  # runs for the project being compiled.

  enabled? =
    Code.ensure_loaded?(Mix.Project) and Code.ensure_loaded?(Boundary) and
      :boundary in Keyword.get(Mix.Project.config(), :compilers, [])

  if enabled? do
    defmacro __using__(opts), do: quote(do: use(Boundary, unquote(opts)))

    # Every boundary uses this module, so none may be checked for it.
    # Quoted, so that nothing refers to `Boundary` when it is not there.
    Code.eval_quoted(
      quote(do: use(Boundary, top_level?: true, check: [in: false, out: false])),
      [],
      __ENV__
    )
  else
    defmacro __using__(_opts), do: nil
  end
end
