defmodule Limen.Challenge.Page do
  @moduledoc """
  The challenge interstitial.

  The page has no inline scripts or styles: it loads `solver.js` and
  `challenge.css` from the challenge path, reads the challenge from `data-`
  attributes, and is served with its own strict Content-Security-Policy.
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

  EEx.function_from_string(
    :defp,
    :template,
    """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="robots" content="noindex, nofollow">
    <title>Checking your browser</title>
    <link rel="stylesheet" href="<%= @css %>">
    <script src="<%= @solver %>" defer></script>
    <%= if @refresh do %><noscript><meta http-equiv="refresh" content="<%= @refresh %>"></noscript><% end %>
    </head>
    <body>
    <main id="limen-challenge" data-token="<%= @token %>" data-difficulty="<%= @difficulty %>" data-worker="<%= @worker %>">
    <h1>Checking your browser</h1>
    <p id="limen-status">This takes a moment and only happens once in a while.</p>
    <progress></progress>
    <noscript><p><%= @no_js %></p></noscript>
    <form id="limen-form" method="post" action="<%= @verify %>">
    <input type="hidden" name="token" value="<%= @token %>">
    <input type="hidden" name="nonce" value="">
    <input type="hidden" name="return_to" value="<%= @return_to %>">
    <input type="hidden" name="instance" value="<%= @instance %>">
    </form>
    </main>
    </body>
    </html>
    """,
    [:assigns]
  )

  @doc """
  The Content-Security-Policy the page is served with.
  """
  @spec content_security_policy() :: String.t()
  def content_security_policy, do: @csp

  @doc """
  Renders the page for `token`.
  """
  @spec render(String.t(), pos_integer(), String.t(), Limen.Instance.t()) :: String.t()
  def render(token, difficulty, return_to, %Limen.Instance{name: name, config: config}) do
    %{path: base, no_js: no_js} = config.challenge
    instance = Atom.to_string(name)

    query =
      URI.encode_query(%{"token" => token, "return_to" => return_to, "instance" => instance})

    {refresh, message} =
      case no_js do
        {:meta_refresh, seconds} ->
          {"#{seconds};url=#{base}/wait?#{query}",
           "JavaScript is disabled, so this takes a little longer: " <>
             "you will be taken to the page in #{seconds} seconds."}

        :deny ->
          {nil, "Please enable JavaScript to continue."}
      end

    template(%{
      token: escape(token),
      instance: escape(instance),
      difficulty: difficulty,
      return_to: escape(return_to),
      refresh: refresh && escape(refresh),
      no_js: escape(message),
      css: escape(Assets.url(base, "challenge.css")),
      solver: escape(Assets.url(base, "solver.js")),
      worker: escape(Assets.url(base, "worker.js")),
      verify: escape(base <> "/verify")
    })
  end

  defp escape(value), do: Plug.HTML.html_escape(value)
end
