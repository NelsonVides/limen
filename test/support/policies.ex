defmodule Limen.Test.Policies do
  @moduledoc """
  Policies used across tests.
  """

  defmodule Scoring do
    @moduledoc false
    use Limen.Policy

    allow :trusted_office, when: signal(:client_ip) in list(:test_office)
    deny :bad_ja4, when: signal(:ja4) in list(:test_bad_ja4), ban: 60

    score :curl, 30, when: signal(:ua_family) == :tool
    score :no_accept_language, 20, when: missing_header("accept-language")
    score :api_path, 10, when: String.starts_with?(path(), "/api")
    score :trusted_header, -50, when: header("x-test-trust") == "yes"
    score :burst, 25, when: rate(:prefix, per: :second) > 3
    score :broken, 100, when: String.length(header("x-missing")) > 0

    decide do
      score >= 70 -> {:deny, ban: 30}
      score >= 40 -> {:challenge, difficulty: difficulty_for(score)}
      score >= 30 -> {:throttle, retry_after: 5}
    end
  end

  defmodule Mazing do
    @moduledoc false
    use Limen.Policy, signals: [Limen.Signal.HttpShape]

    maze :scraper, when: signal(:ua_family) == :tool, ban: 120
    score :no_accept_language, 50, when: missing_header("accept-language")

    decide do
      score >= 50 -> :maze
      true -> :allow
    end
  end

  defmodule Limited do
    @moduledoc false
    use Limen.Policy, signals: []

    limit :per_client, key: :prefix, rate: 2, per: :second, burst: 1

    decide do
      true -> :allow
    end
  end

  defmodule Tarpit do
    @moduledoc false
    use Limen.Policy, signals: [], mode: :enforce

    deny :always, when: true

    decide do
      true -> {:tarpit, delay: 10}
    end
  end

  defmodule TarpitAll do
    @moduledoc false
    use Limen.Policy, signals: [], mode: :enforce

    decide do
      true -> {:tarpit, delay: 20}
    end
  end

  defmodule Challenging do
    @moduledoc false
    use Limen.Policy, signals: [], mode: :enforce

    decide do
      true -> {:challenge, difficulty: 8}
    end
  end

  defmodule Login do
    @moduledoc false
    use Limen.Policy, signals: []

    score :any, 100, when: true

    decide do
      score >= 100 -> :deny
    end
  end
end
