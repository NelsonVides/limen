defmodule Limen.Challenge.Page do
  @moduledoc """
  The challenge interstitial, and how to make it your own.

  The page has no inline scripts or styles: it loads `solver.js` and
  `challenge.css` from the challenge path, reads the challenge from `data-`
  attributes, and is served with its own strict Content-Security-Policy
  (`content_security_policy/0`).

  ## Your own words

  The page is in English unless the instance's `:page` (an option of the
  `:challenge` configuration) is a module of yours implementing this
  behaviour. `text/2` is called for every page served, with the request, so
  it can speak the visitor's language:

      defmodule MyAppWeb.ChallengePage do
        use Limen.Challenge.Page
        use Gettext, backend: MyAppWeb.Gettext

        @impl true
        def text(conn, vars) do
          Gettext.put_locale(MyAppWeb.Gettext, MyAppWeb.Locale.from_conn(conn))

          %{
            lang: Gettext.get_locale(MyAppWeb.Gettext),
            title: gettext("Checking your browser"),
            heading: gettext("Checking your browser"),
            message: gettext("This takes a moment and only happens once in a while."),
            no_js: no_js(vars)
          }
        end

        defp no_js(%{seconds: nil}), do: gettext("Please enable JavaScript to continue.")

        defp no_js(%{seconds: seconds}),
          do: gettext("You will be taken to the page in %{seconds} seconds.", seconds: seconds)
      end

      config :my_app, Limen, challenge: [page: MyAppWeb.ChallengePage]

  It returns any of these keys, as plain text; the rest keep their English
  defaults (see `default_text/1`):

    * `:lang` - the page's language, for `<html lang>`;
    * `:title`, `:heading` and `:message` - what the visitor reads while the
      check runs;
    * `:no_js` - what visitors without JavaScript read: how long they wait
      when `vars.seconds` is an integer (`no_js: {:meta_refresh, seconds}`),
      or that they need JavaScript when it is `nil` (`no_js: :deny`);
    * `:solved`, `:failed` and `:unsupported` - what the script shows when
      the check succeeds, cannot run, or the browser has no Web Workers.

  `text/2` runs on the request path of every challenged navigation: no
  calls to processes, and nothing slow.

  ## Your own page

  `render/1` returns the whole page. Override it to change the markup, for
  example to add your own stylesheet, which the page's
  Content-Security-Policy allows as long as it comes from your own origin:

      @impl true
      def render(assigns) do
        Limen.Challenge.Page.template(%{assigns | stylesheets: assigns.stylesheets ++ ["/assets/challenge.css"]})
      end

  A page of your own must keep the contract with `solver.js`, and use no
  inline scripts or styles (the Content-Security-Policy blocks them): an
  element with the id `limen-challenge` and `data-token`, `data-difficulty`
  and `data-worker` attributes (and optionally `data-text-solved`,
  `data-text-failed` and `data-text-unsupported`), an element with the id
  `limen-status` for messages, a `form` with the id `limen-form` posting to
  `verify` the hidden fields `token`, `nonce` (empty), `return_to` and
  `instance`, and a `<script src>` for `solver`. `template/1` is the
  reference. Assigns are not escaped: escape them, as `template/1` does.

  Assigns:

    * `:text` - the texts above, merged over the defaults;
    * `:token`, `:difficulty`, `:return_to` and `:instance` - the challenge;
    * `:solver`, `:worker` and `:verify` - the URLs of the script, its
      worker and the verification endpoint;
    * `:stylesheets` - stylesheet URLs, Limen's by default;
    * `:refresh` - the content of the no-JavaScript meta refresh, or `nil`.
  """

  alias Limen.Challenge.Assets

  require EEx

  @csp Enum.join(
         [
           "default-src 'none'",
           "script-src 'self'",
           "worker-src 'self'",
           "style-src 'self'",
           "connect-src 'self'",
           "form-action 'self'",
           "base-uri 'none'",
           "frame-ancestors 'none'"
         ],
         "; "
       )

  @typedoc "What `text/2` knows about the page: the no-JavaScript wait, if any."
  @type vars :: %{seconds: non_neg_integer() | nil}

  @doc """
  The page's texts for the request, in any subset: see the module
  documentation for the keys.
  """
  @callback text(conn :: Plug.Conn.t(), vars()) :: map() | keyword()

  @doc """
  The page, from the assigns described in the module documentation.
  """
  @callback render(assigns :: map()) :: iodata()

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour Limen.Challenge.Page

      @impl Limen.Challenge.Page
      def text(_conn, _vars), do: %{}

      @impl Limen.Challenge.Page
      def render(assigns), do: unquote(__MODULE__).template(assigns)

      defoverridable text: 2, render: 1
    end
  end

  # Limen's own page, the default `:page`, keeps the English texts.
  @doc false
  @spec text(Plug.Conn.t(), vars()) :: map()
  def text(_conn, _vars), do: %{}

  @doc false
  @spec render(map()) :: String.t()
  def render(assigns), do: template(assigns)

  @doc """
  The English texts, for `vars`.
  """
  @spec default_text(vars()) :: map()
  def default_text(%{seconds: seconds}) do
    %{
      lang: "en",
      title: "Checking your browser",
      heading: "Checking your browser",
      message: "This takes a moment and only happens once in a while.",
      no_js:
        if(seconds,
          do:
            "JavaScript is disabled, so this takes a little longer: " <>
              "you will be taken to the page in #{seconds} seconds.",
          else: "Please enable JavaScript to continue."
        ),
      solved: "Done, taking you there…",
      failed: "The check could not run in this browser.",
      unsupported: "Your browser cannot run the check. Please use a recent browser."
    }
  end

  @doc """
  The Content-Security-Policy the page is served with.
  """
  @spec content_security_policy() :: String.t()
  def content_security_policy, do: @csp

  @doc """
  Renders Limen's page from `assigns`, escaping them.
  """
  @spec template(map()) :: String.t()
  EEx.function_from_string(
    :def,
    :template,
    """
    <!doctype html>
    <html lang="<%= e(@text.lang) %>">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="robots" content="noindex, nofollow">
    <title><%= e(@text.title) %></title>
    <%= for href <- @stylesheets do %><link rel="stylesheet" href="<%= e(href) %>">
    <% end %><script src="<%= e(@solver) %>" defer></script>
    <%= if @refresh do %><noscript><meta http-equiv="refresh" content="<%= e(@refresh) %>"></noscript><% end %>
    </head>
    <body>
    <main id="limen-challenge" data-token="<%= e(@token) %>" data-difficulty="<%= @difficulty %>" data-worker="<%= e(@worker) %>" data-text-solved="<%= e(@text.solved) %>" data-text-failed="<%= e(@text.failed) %>" data-text-unsupported="<%= e(@text.unsupported) %>">
    <h1><%= e(@text.heading) %></h1>
    <p id="limen-status"><%= e(@text.message) %></p>
    <progress></progress>
    <noscript><p><%= e(@text.no_js) %></p></noscript>
    <form id="limen-form" method="post" action="<%= e(@verify) %>">
    <input type="hidden" name="token" value="<%= e(@token) %>">
    <input type="hidden" name="nonce" value="">
    <input type="hidden" name="return_to" value="<%= e(@return_to) %>">
    <input type="hidden" name="instance" value="<%= e(@instance) %>">
    </form>
    </main>
    </body>
    </html>
    """,
    [:assigns]
  )

  @doc false
  # The page for a challenge, rendered by the instance's page module.
  @spec build(Plug.Conn.t(), String.t(), pos_integer(), String.t(), Limen.Instance.t()) ::
          iodata()
  def build(conn, token, difficulty, return_to, %Limen.Instance{name: name, config: config}) do
    %{path: base, no_js: no_js, page: page} = config.challenge
    instance = Atom.to_string(name)

    {refresh, vars} =
      case no_js do
        {:meta_refresh, seconds} ->
          query =
            URI.encode_query(%{
              "token" => token,
              "return_to" => return_to,
              "instance" => instance
            })

          {"#{seconds};url=#{base}/wait?#{query}", %{seconds: seconds}}

        :deny ->
          {nil, %{seconds: nil}}
      end

    page.render(%{
      text: Map.merge(default_text(vars), Map.new(page.text(conn, vars))),
      token: token,
      instance: instance,
      difficulty: difficulty,
      return_to: return_to,
      refresh: refresh,
      stylesheets: [Assets.url(base, "challenge.css")],
      solver: Assets.url(base, "solver.js"),
      worker: Assets.url(base, "worker.js"),
      verify: base <> "/verify"
    })
  end

  defp e(value), do: Plug.HTML.html_escape(to_string(value))
end
