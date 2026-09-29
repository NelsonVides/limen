defmodule Limen.Trap do
  @moduledoc """
  Honeypots: places only automated clients go, and what happens when they do.

  People follow the links they can see and fill in the fields they are
  shown. Scrapers follow every link in the markup and fill in every field of
  a form. Limen offers two kinds of traps built on that difference, and a
  client that falls into either is flagged: its prefix is banned with
  `action: :maze` for the trap's `:ban` seconds, and it gets the endless,
  slow pages of `Limen.Maze` instead of your application from then on. It is
  never told it was caught.

  ## Link traps

  Configure one or more trap paths, which Limen answers before your
  application sees them:

      config :my_app, Limen, trap: [paths: ["/archive/directory"]]

  then make sure only a scraper can get there: disallow the paths in
  [`robots.txt`][robots.txt] (`robots/1`), the file where a site tells
  crawlers what not to fetch, so well-behaved crawlers stay away, and put a
  link to them that people never see in your layout (`link/2`):

      <footer>
        ...
        {Limen.Trap.link(:my_app)}
      </footer>

  A request under a trap path settles at the `:trap` stage: its decision
  records the trap, the prefix is flagged, and the client is served a maze
  page whose links all lead further into the trap. Crawlers verified by
  reverse DNS (see `Limen.Signal.Fcrdns`) are never flagged, and neither are
  requests claiming to be a crawler whose verification is still pending.

  ## Form traps

  In a form people fill in (sign up, contact, comments), add a decoy field
  and a signed timestamp with `form_fields/2`, and check the submission with
  `check_form/3`:

      <.form for={@form} phx-submit="save">
        {Limen.Trap.form_fields(:my_app)}
        ...
      </.form>

      case Limen.Trap.check_form(conn, params, otp_app: :my_app) do
        {:ok, _decision} -> create_account(params)
        {:trapped, _decision} -> pretend_it_worked(conn)
      end

  A submission is trapped when the decoy field is filled in, when it came
  faster than `:min_fill_time` after the form was rendered, or when its
  timestamp is missing or forged. Answer trapped submissions as if they
  succeeded, so the client learns nothing.

  ## Dry-run

  In dry-run mode traps work exactly the same, except for the final action:
  the decision is recorded with `enforced: false`, the flag is recorded as a
  dry-run ban (reported, never enforced), requests under trap paths continue
  to your application, and `check_form/3` returns `{:ok, decision}`.

  See the `:trap` options in `Limen.Config`, and the honeypots guide.

  [robots.txt]: https://www.rfc-editor.org/rfc/rfc9309
  """

  alias Limen.{Context, Decision, Gate, Instance, Signal}
  alias Limen.Decision.Match
  alias Limen.Signal.Fcrdns
  alias Limen.State.BanList

  @token_param "_limen_form"
  @version 1

  # Out of sight and out of the tab order, without relying on the
  # application's stylesheet.
  @hidden "position:absolute;left:-10000px;top:auto;width:1px;height:1px;overflow:hidden"

  @doc """
  The trap paths of `instance`.
  """
  @spec paths(atom() | Instance.t()) :: [String.t()]
  def paths(instance), do: Instance.fetch!(instance).config.trap.paths

  @doc """
  The `robots.txt` lines keeping well-behaved crawlers out of the traps of
  `instance`, one `Disallow` line per trap path.

      get "/robots.txt", fn conn ->
        text(conn, "User-agent: *\\n" <> Limen.Trap.robots(:my_app))
      end
  """
  @spec robots(atom() | Instance.t()) :: String.t()
  def robots(instance), do: Enum.map_join(paths(instance), &"Disallow: #{&1}\n")

  @doc """
  A URL under a trap path, for links only automated clients follow.

  It reads like any other URL of the maze and is the same every time for an
  instance (it is derived from the instance's secret).

  ## Options

    * `:path` - the trap path to link into. Defaults to the first one.
  """
  @spec href(atom() | Instance.t(), keyword()) :: String.t()
  def href(instance, opts \\ []) do
    instance = Instance.fetch!(instance)
    path = trap_path!(instance, opts)
    {_text, slug} = Limen.Maze.name(instance, ["link", 0, path], 2..4)
    path <> "/" <> slug
  end

  @doc """
  A link to a trap that people never see.

  The link is kept off screen, out of the tab order (`tabindex="-1"`), away
  from assistive technologies (`aria-hidden`) and away from crawlers that
  honour `rel="nofollow"`. Returns `{:safe, iodata}`, which Phoenix templates
  render as is; elsewhere, use the iodata.

  ## Options

    * `:path` - the trap path to link into. Defaults to the first one.
    * `:text` - the link text. Defaults to a phrase of the instance's maze.
    * `:class` - a CSS class hiding the link, used instead of the inline
      `style` attribute, for pages whose Content-Security-Policy forbids
      inline styles.
  """
  @spec link(atom() | Instance.t(), keyword()) :: {:safe, iodata()}
  def link(instance, opts \\ []) do
    instance = Instance.fetch!(instance)
    path = trap_path!(instance, opts)
    {text, slug} = Limen.Maze.name(instance, ["link", 0, path], 2..4)
    text = Keyword.get(opts, :text, text)

    {:safe,
     [
       "<a href=\"",
       escape(path <> "/" <> slug),
       "\" rel=\"nofollow\" tabindex=\"-1\" aria-hidden=\"true\" ",
       hiding(opts),
       ">",
       escape(text),
       "</a>"
     ]}
  end

  defp trap_path!(%Instance{name: name, config: %{trap: %{paths: paths}}}, opts) do
    case {Keyword.get(opts, :path), paths} do
      {nil, [path | _rest]} ->
        path

      {path, paths} when is_binary(path) ->
        if path in paths,
          do: path,
          else: raise(ArgumentError, "#{inspect(path)} is not a trap path")

      {nil, []} ->
        raise ArgumentError, "the Limen instance #{inspect(name)} has no trap paths"
    end
  end

  @doc """
  The hidden fields of a form trap: a decoy field people never see, and a
  signed timestamp of when the form was rendered.

  Returns `{:safe, iodata}` to put inside a form. Check submissions with
  `check_form/3`.

  ## Options

    * `:class` - a CSS class hiding the decoy field, used instead of the
      inline `style` attribute.
  """
  @spec form_fields(atom() | Instance.t(), keyword()) :: {:safe, iodata()}
  def form_fields(instance, opts \\ []) do
    %Instance{config: %{trap: %{form_field: field}, keys: %{trap: [key | _previous]}}} =
      Instance.fetch!(instance)

    label = String.capitalize(String.replace(field, ["_", "-"], " "))

    {:safe,
     [
       "<div aria-hidden=\"true\" ",
       hiding(opts),
       "><label>",
       label,
       " <input type=\"text\" name=\"",
       field,
       "\" value=\"\" tabindex=\"-1\" autocomplete=\"off\"></label></div>",
       "<input type=\"hidden\" name=\"",
       @token_param,
       "\" value=\"",
       token(key, System.system_time(:millisecond)),
       "\">"
     ]}
  end

  defp hiding(opts) do
    case Keyword.fetch(opts, :class) do
      {:ok, class} -> ["class=\"", escape(class), "\""]
      :error -> ["style=\"", @hidden, "\""]
    end
  end

  defp token(key, issued_at) do
    payload = <<@version, issued_at::64>>
    Base.url_encode64(payload <> mac(key, payload), padding: false)
  end

  defp mac(key, payload), do: binary_part(Limen.HMAC.sha256(key, payload), 0, 16)

  @doc """
  Checks a form submission for the tells of `form_fields/2`.

  `source` is the `Plug.Conn` of the submission, or, from a LiveView, its
  connect info (see `Limen.LiveView.check_form/3`). `params` are the
  submitted fields; the trap's fields are read from the top level.

  Every check is a decision at the `:trap` stage, emitted and sampled like
  any other. A trapped submission also flags the client prefix for the
  maze.

  ## Options

    * `:instance` or `:otp_app` - the instance checking the form, as for
      `Limen.Plug`. Defaults, for a `Plug.Conn`, to the instance that made
      the decision for the request.
    * `:mode` - `:dry_run` or `:enforce`, overriding the instance's mode.
    * `:facts` - for connect info, facts about the connection, as for
      `Limen.put_facts/2`. A `Plug.Conn` carries its own.

  Returns `{:trapped, decision}` when the submission must not be acted on
  (never in dry-run mode), and `{:ok, decision}` otherwise.
  """
  @spec check_form(Plug.Conn.t() | map(), map(), keyword()) ::
          {:ok, Decision.t()} | {:trapped, Decision.t()}
  def check_form(source, params, opts \\ []) do
    started = System.monotonic_time()
    {ctx, conn} = context(source, opts)
    %Context{instance: %Instance{config: config} = instance} = ctx
    mode = Keyword.get(opts, :mode) || ctx.mode || config.mode
    ctx = Signal.identify(ctx, config)
    tells = tells(params || %{}, ctx, config)

    decision =
      tells
      |> form_decision(ctx, mode)
      |> record(ctx)
      |> Gate.finalize(ctx, started)

    :ok = Gate.emit(decision, conn, instance)
    if decision.enforced, do: {:trapped, decision}, else: {:ok, decision}
  end

  defp context(%Plug.Conn{} = conn, opts) do
    name =
      case {opts, Limen.decision(conn)} do
        {opts, %Decision{instance: name}} when name != nil ->
          if Keyword.has_key?(opts, :instance) or Keyword.has_key?(opts, :otp_app),
            do: Instance.name!(opts),
            else: name

        {opts, _none} ->
          Instance.name!(opts)
      end

    {Context.from_conn(conn, Instance.fetch!(name)), conn}
  end

  defp context(connect_info, opts) when is_map(connect_info) do
    instance = Instance.fetch!(Instance.name!(opts))
    {Limen.Socket.context(connect_info, instance, opts), nil}
  end

  defp tells(params, ctx, %{trap: trap, keys: %{trap: keys}}) do
    decoy =
      case Map.get(params, trap.form_field) do
        value when value in [nil, ""] -> []
        _filled -> [:decoy]
      end

    timing =
      case read_token(Map.get(params, @token_param), keys) do
        {:ok, issued_at} when ctx.now - issued_at < trap.min_fill_time ->
          [{:too_fast, ctx.now - issued_at}]

        {:ok, issued_at} ->
          [{:filled_in, ctx.now - issued_at}]

        {:error, reason} ->
          [{:token, reason}]
      end

    decoy ++ timing
  end

  defp read_token(nil, _keys), do: {:error, :missing}

  defp read_token(token, keys) when is_binary(token) do
    with {:ok, <<@version, issued_at::64, mac::binary-16>>} <-
           Base.url_decode64(token, padding: false),
         true <-
           Enum.any?(keys, &Plug.Crypto.secure_compare(mac(&1, <<@version, issued_at::64>>), mac)) do
      {:ok, issued_at}
    else
      _invalid -> {:error, :invalid}
    end
  end

  defp read_token(_token, _keys), do: {:error, :invalid}

  defp form_decision([{:filled_in, elapsed}], _ctx, mode) do
    match = %Match{
      name: :form_filled_in,
      kind: :pass,
      condition: "no form trap was triggered",
      observed: [{"elapsed_ms", elapsed}]
    }

    %Decision{action: :allow, stage: :trap, mode: mode, matches: [match]}
  end

  defp form_decision(tells, %Context{instance: instance}, mode) do
    %{form_field: field, min_fill_time: min_fill_time, ban: ban} = instance.config.trap

    matches =
      tells
      |> Enum.map(&form_match(&1, field, min_fill_time))
      |> Enum.reject(&is_nil/1)

    %Decision{action: :maze, params: %{ban: ban}, stage: :trap, mode: mode, matches: matches}
  end

  defp form_match(:decoy, field, _min) do
    %Match{
      name: :form_decoy,
      kind: :trap,
      condition: "filled in the hidden field",
      observed: [{"field", field}]
    }
  end

  defp form_match({:too_fast, elapsed}, _field, min) do
    %Match{
      name: :form_too_fast,
      kind: :trap,
      condition: "submitted less than #{min} ms after the form was rendered",
      observed: [{"elapsed_ms", elapsed}]
    }
  end

  defp form_match({:token, reason}, _field, _min) do
    %Match{
      name: :form_token,
      kind: :trap,
      condition: "a valid form timestamp",
      observed: [{"token", reason}]
    }
  end

  # A trap filled in slowly still gives the elapsed time, which only matters
  # when nothing else was triggered.
  defp form_match({:filled_in, _elapsed}, _field, _min), do: nil

  @doc false
  # The decision for a request under a trap path.
  @spec decide(Context.t(), String.t()) :: {Decision.t(), Context.t()}
  def decide(%Context{instance: instance} = ctx, path) do
    ctx = Signal.collect(ctx, [Fcrdns])
    mode = ctx.mode || instance.config.mode

    trap = %Match{
      name: :trap,
      kind: :trap,
      condition: "requested a trap path",
      observed: [{"trap", path}, {"path", ctx.path}]
    }

    decision =
      case ctx.signals do
        %{fcrdns: claim} when claim in [:verified, :pending] ->
          exempt = %Match{
            name: :crawler,
            kind: :allow,
            condition: "signal(:fcrdns) in [:verified, :pending]",
            observed: [{"signal(:fcrdns)", claim}]
          }

          %Decision{action: :allow, stage: :trap, mode: mode, matches: [trap, exempt]}

        _not_a_crawler ->
          %Decision{
            action: :maze,
            params: %{ban: instance.config.trap.ban},
            stage: :trap,
            mode: mode,
            matches: [trap]
          }
      end

    {decision, ctx}
  end

  # Flags trapped clients for the maze. Like any ban, the flag carries the
  # decision's mode, so a dry-run flag is never enforced.
  defp record(
         %Decision{action: :maze, params: %{ban: ttl}, matches: [match | _rest]} = decision,
         %Context{instance: instance, prefix: prefix, now: now}
       )
       when prefix != nil do
    Limen.Stats.incr(instance, :trap_hit)
    opts = [mode: decision.mode, origin: :trap, action: :maze, reason: match.name, now: now]
    _result = BanList.ban(instance, prefix, ttl, opts)
    decision
  end

  defp record(decision, _ctx), do: decision

  defp escape(text), do: Plug.HTML.html_escape_to_iodata(text)
end
