defmodule Limen.Policy.Default do
  @moduledoc """
  The policy `Limen.Plug` uses when none is given.

  A conservative starting point meant to be run in dry-run mode first: it
  lets through clients in `list(:allow)` and crawlers verified by DNS,
  challenges clearly automated traffic, denies only extreme scores, and never
  bans. Copy it into your application to tune it.

  Its rules are listed by `Limen.Policy.describe/1`:

      iex> Limen.Policy.describe(Limen.Policy.Default) =~ "score +30 tool_user_agent"
      true
  """

  use Limen.Policy

  limit :flood, key: :prefix, rate: 100, per: :second, burst: 200

  allow :allow_listed, when: signal(:client_ip) in list(:allow)
  allow :verified_crawler, when: signal(:fcrdns) == :verified
  deny :known_bad_ja4, when: signal(:ja4) in list(:bad_ja4)

  score :spoofed_crawler, 80, when: signal(:fcrdns) == :failed
  score :tool_user_agent, 30, when: signal(:ua_family) == :tool
  score :headless_browser, 40, when: shape_flag(:headless)
  score :no_user_agent, 40, when: shape_flag(:no_user_agent)
  score :no_accept_language, 15, when: shape_flag(:no_accept_language)
  score :generic_accept, 15, when: shape_flag(:generic_accept)
  score :no_sec_fetch, 25, when: shape_flag(:no_sec_fetch)
  score :no_client_hints, 25, when: shape_flag(:no_client_hints)

  score :client_hint_mismatch, 35,
    when:
      shape_flag(:unexpected_client_hints) or shape_flag(:client_hint_brand_mismatch) or
        shape_flag(:client_hint_platform_mismatch) or shape_flag(:client_hint_mobile_mismatch)

  score :hosting_asn, 25, when: signal(:asn_kind) == :hosting
  score :burst, 30, when: rate(:prefix, per: :second) > 20
  score :sustained, 20, when: rate(:prefix, per: :minute) > 300

  score :probing, 25, when: signal(:not_found_ratio) > 0.5 and signal(:requests_per_minute) >= 10

  decide do
    score >= 150 -> :deny
    score >= 50 -> {:challenge, difficulty: difficulty_for(score)}
    true -> :allow
  end
end
