defmodule Limen.Maze.Model do
  @moduledoc """
  The language model maze pages are written with.

  A word-level [Markov chain] learnt from a corpus: for every pair of
  consecutive words, the words that followed them and how often. Sentences
  are drawn one word at a time from the two words before. Where the corpus
  offers a single continuation, the chain sometimes backs off to the words
  that followed the last word alone, so sentences recombine instead of
  repeating the corpus verbatim.

  Everything that can be is done when the model is built: words are
  HTML-escaped and turned into URL slug fragments once, and every set of
  continuations becomes a `Limen.Maze.Dice`, so drawing a word is a map
  lookup and a single random integer. `Limen.Maze.Bundled` holds the model of
  Limen's own corpus, built at compile time; instances with a `:corpus` of
  their own build theirs when they start.

  ## Corpus format

  Plain text, one or more sentences per line. Lines starting with `#` are
  comments. Sentences end with `.`, `!` or `?`; a line that does not is
  treated as a sentence of its own. Write prose that reads like your site:
  product descriptions, articles, help pages. Very short sentences (under
  three words) are skipped.

  [Markov chain]: https://en.wikipedia.org/wiki/Markov_chain
  """

  alias Limen.Maze.Dice

  @enforce_keys [:words, :bare, :slugs, :leads, :chain, :backoff]
  defstruct [:words, :bare, :slugs, :leads, :chain, :backoff]

  @type t :: %__MODULE__{
          words: tuple(),
          bare: tuple(),
          slugs: tuple(),
          leads: tuple(),
          chain: %{{non_neg_integer(), non_neg_integer()} => Dice.t()},
          backoff: %{non_neg_integer() => Dice.t()}
        }

  # Word id 0 marks the start and the end of a sentence.
  @boundary 0
  @max_words 40

  # Words after which a noun phrase usually starts, where titles and link
  # texts are best taken from.
  @leads ~w(a an the our your their its this these each every all any some new)

  # Words that make titles and link texts look cut off when they end them.
  @dangling ~w(a about after all also an and any are as at be been before but by can could
               did do does each every for from had has have if in into is it its may more most
               much new not of on or our should so some such than that the their them then there
               these they this those to until us was we were when where which while who will
               with would you your)

  @doc """
  Builds a model from corpus texts.

  Raises `ArgumentError` when the texts hold no usable sentence.
  """
  @spec build([String.t()]) :: t()
  def build(texts) when is_list(texts) do
    {vocabulary, encoded} = encode(Enum.flat_map(texts, &sentences/1))

    %__MODULE__{
      words: dictionary(vocabulary, "", &escape/1),
      bare: dictionary(vocabulary, "", &escape(bare(&1))),
      slugs: dictionary(vocabulary, "", &slug_fragment/1),
      leads: dictionary(vocabulary, false, &lead?/1),
      chain: dice(Enum.flat_map(encoded, &pairs/1)),
      backoff: dice(Enum.flat_map(encoded, &singles/1))
    }
  end

  # Everything the maze needs to know about a word, by word id.
  defp dictionary(vocabulary, boundary, fun),
    do: List.to_tuple([boundary | Enum.map(vocabulary, fun)])

  @doc """
  Reads the sentences of a corpus text, as lists of words.
  """
  @spec sentences(String.t()) :: [[String.t()]]
  def sentences(text) when is_binary(text) do
    text
    |> String.split(~r/\R/u)
    |> Enum.reject(&String.starts_with?(String.trim_leading(&1), "#"))
    |> Enum.flat_map(&String.split(&1, ~r/(?<=[.!?])\s+/u, trim: true))
    |> Enum.map(&String.split(&1, ~r/\s+/u, trim: true))
    |> Enum.filter(&(length(&1) >= 3))
    |> Enum.map(&terminate/1)
  end

  defp terminate(words) do
    last = List.last(words)

    if String.ends_with?(last, [".", "!", "?"]),
      do: words,
      else: List.replace_at(words, -1, last <> ".")
  end

  defp lead?(word), do: String.downcase(word) in @leads

  # Words become ids, from 1 on, in order of first appearance.
  defp encode([]),
    do: raise(ArgumentError, "the maze corpus has no sentence of three words or more")

  defp encode(sentences) do
    vocabulary = Enum.uniq(List.flatten(sentences))
    ids = Map.new(Enum.with_index(vocabulary, 1))
    {vocabulary, Enum.map(sentences, fn words -> Enum.map(words, &Map.fetch!(ids, &1)) end)}
  end

  # Transitions from the two previous words, and from the previous word alone.
  defp pairs(sentence) do
    padded = [@boundary, @boundary | List.insert_at(sentence, -1, @boundary)]
    for [a, b, c] <- Enum.chunk_every(padded, 3, 1, :discard), do: {{a, b}, c}
  end

  defp singles(sentence) do
    padded = [@boundary | List.insert_at(sentence, -1, @boundary)]
    for [a, b] <- Enum.chunk_every(padded, 2, 1, :discard), do: {a, b}
  end

  defp dice(transitions) do
    transitions
    |> Enum.frequencies()
    |> Enum.group_by(fn {{state, _next}, _count} -> state end, fn {{_s, next}, n} -> {next, n} end)
    |> Map.new(fn {state, weighted} -> {state, Dice.new(Enum.sort(weighted))} end)
  end

  defp escape(word), do: IO.iodata_to_binary(Plug.HTML.html_escape_to_iodata(word))

  defp bare(word), do: String.replace(word, ~r/^[,;:.!?"'()\[\]]+|[,;:.!?"'()\[\]]+$/u, "")

  # Small words get no fragment, so slugs and phrases never end on them.
  defp slug_fragment(word) do
    word
    |> String.downcase()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/[^a-z0-9-]/u, "")
    |> String.trim("-")
    |> then(&if &1 in @dangling, do: "", else: &1)
  end

  @doc """
  Draws a sentence, as a list of word ids.
  """
  @spec sentence(t(), :rand.state()) :: {[pos_integer()], :rand.state()}
  def sentence(%__MODULE__{} = model, state), do: walk(model, @boundary, @boundary, [], state)

  defp walk(_model, _a, _b, words, state) when length(words) >= @max_words,
    do: {Enum.reverse(words), state}

  defp walk(model, a, b, words, state) do
    case step(model, a, b, state) do
      {@boundary, state} -> {Enum.reverse(words), state}
      {next, state} -> walk(model, b, next, [next | words], state)
    end
  end

  # A pair of words the corpus only ever continued one way is left, a third
  # of the time, for any word that followed the last one.
  defp step(%__MODULE__{chain: chain, backoff: backoff}, a, b, state) do
    case Map.fetch(chain, {a, b}) do
      {:ok, %Dice{size: 1} = die} when b != @boundary ->
        case :rand.uniform_s(3, state) do
          {1, state} -> Dice.roll(Map.fetch!(backoff, b), state)
          {_other, state} -> Dice.roll(die, state)
        end

      {:ok, die} ->
        Dice.roll(die, state)

      :error ->
        Dice.roll(Map.fetch!(backoff, b), state)
    end
  end

  @doc """
  Renders word ids as a sentence: HTML-escaped words separated by spaces,
  ending in punctuation.
  """
  @spec render(t(), [pos_integer()]) :: iolist()
  def render(%__MODULE__{words: words} = model, ids) do
    text = words(model, ids)
    if ends_sentence?(words, List.last(ids)), do: text, else: [text, "."]
  end

  @doc """
  Renders word ids as they are: HTML-escaped words separated by spaces.
  """
  @spec words(t(), [pos_integer()]) :: iolist()
  def words(%__MODULE__{words: words}, ids), do: Enum.map_intersperse(ids, " ", &elem(words, &1))

  defp ends_sentence?(_words, nil), do: true

  defp ends_sentence?(words, id),
    do: String.ends_with?(elem(words, id), [".", "!", "?", ".)", "?)"])

  @doc """
  Draws a short phrase of `min..max` words, for titles and link texts.

  Phrases start after a determiner when the sentence drawn has one, so they
  tend to be noun phrases, and never end on a small word.
  """
  @spec phrase(t(), Range.t(), :rand.state()) :: {[pos_integer()], :rand.state()}
  def phrase(%__MODULE__{} = model, min..max//_step, state), do: phrase(model, min, max, 3, state)

  defp phrase(model, min, max, attempts, state) do
    {ids, state} = sentence(model, state)
    {ids, state} = after_lead(model, ids, state)
    {length, state} = between(min, max, state)

    case {trim(model, Enum.take(ids, length)), attempts} do
      {[], 0} -> {Enum.take(ids, 1), state}
      {[], attempts} -> phrase(model, min, max, attempts - 1, state)
      {ids, _attempts} -> {ids, state}
    end
  end

  defp after_lead(%__MODULE__{leads: leads}, ids, state) do
    starts =
      for {id, index} <- Enum.with_index(ids),
          elem(leads, id),
          index + 1 < length(ids),
          do: index + 1

    case starts do
      [] ->
        {ids, state}

      starts ->
        {pick, state} = :rand.uniform_s(length(starts), state)
        {Enum.drop(ids, Enum.at(starts, pick - 1)), state}
    end
  end

  defp trim(%__MODULE__{slugs: slugs}, ids) do
    ids
    |> Enum.reverse()
    |> Enum.drop_while(&(elem(slugs, &1) == ""))
    |> Enum.reverse()
  end

  @doc """
  Renders a phrase: its words without punctuation, the first capitalised.
  """
  @spec render_phrase(t(), [pos_integer()]) :: String.t()
  def render_phrase(%__MODULE__{bare: bare}, ids) do
    ids
    |> Enum.map(&elem(bare, &1))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
    |> capitalize()
  end

  defp capitalize(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest
  defp capitalize(""), do: ""

  @doc """
  A URL slug for word ids, such as `"regional-freight-guide"`.
  """
  @spec slug(t(), [pos_integer()]) :: String.t()
  def slug(%__MODULE__{slugs: slugs}, ids) do
    ids
    |> Enum.map(&elem(slugs, &1))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("-")
  end

  @doc """
  The number of distinct words the model knows.
  """
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{words: words}), do: tuple_size(words) - 1

  @doc false
  @spec between(integer(), integer(), :rand.state()) :: {integer(), :rand.state()}
  def between(min, max, state) do
    {offset, state} = :rand.uniform_s(max - min + 1, state)
    {min + offset - 1, state}
  end
end
