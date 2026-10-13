defmodule Foreman.RateLimit do
  @moduledoc "In-memory rate limits for sign-in, enrollment and agent connects."
  use Hammer, backend: :ets
end
