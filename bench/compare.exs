# Compares benchmark results and fails on regressions.
#
#     mix run bench/compare.exs --base base-1.json --base base-2.json \
#       --head head-1.json --head head-2.json [--threshold 0.10]
#
# Each side may have several runs; the fastest median of each scenario is
# used, which filters out runs disturbed by noisy neighbours. Scenarios that
# exist on one side only are reported but never fail the comparison.

{opts, _argv} =
  OptionParser.parse!(System.argv(),
    strict: [base: :keep, head: :keep, threshold: :float]
  )

threshold = Keyword.get(opts, :threshold, 0.10)

read = fn file -> JSON.decode!(File.read!(file)) end

best = fn files ->
  files
  |> Enum.map(read)
  |> Enum.reduce(%{}, fn results, acc ->
    Map.merge(acc, Map.new(results, fn {name, %{"median_ns" => ns}} -> {name, ns} end), fn
      _name, a, b -> min(a, b)
    end)
  end)
end

base = best.(Keyword.get_values(opts, :base))
head = best.(Keyword.get_values(opts, :head))
names = Enum.sort(Enum.uniq(Map.keys(base) ++ Map.keys(head)))

format = fn
  nil -> "-"
  ns -> :erlang.float_to_binary(ns / 1, decimals: 1) <> " ns"
end

rows =
  Enum.map(names, fn name ->
    case {base[name], head[name]} do
      {b, h} when is_number(b) and is_number(h) and b > 0 ->
        change = h / b - 1
        status = if change > threshold, do: "regression", else: "ok"
        {name, b, h, "#{Float.round(change * 100, 1)}%", status}

      {b, h} ->
        {name, b, h, "-", "new or removed"}
    end
  end)

table =
  [
    "| Scenario | Base median | Head median | Change | Status |",
    "|---|---|---|---|---|"
    | Enum.map(rows, fn {name, b, h, change, status} ->
        "| #{name} | #{format.(b)} | #{format.(h)} | #{change} | #{status} |"
      end)
  ]
  |> Enum.join("\n")

Mix.shell().info(table)

if summary = System.get_env("GITHUB_STEP_SUMMARY") do
  File.write!(summary, "## Benchmarks\n\n" <> table <> "\n", [:append])
end

regressions = Enum.filter(rows, &(elem(&1, 4) == "regression"))

if regressions != [] do
  Mix.shell().error(
    "#{length(regressions)} scenario(s) regressed by more than #{round(threshold * 100)}%"
  )

  exit({:shutdown, 1})
end
