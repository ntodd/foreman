defmodule ForemanAgent.Runner.Logged do
  @moduledoc """
  Commands whose output goes to an operation's log: re-chunked into
  lines, without colors, cursor movement or redrawn spinner frames.

  The context is an operation's: `%{runner: module, log: fn stream, data -> ... end}`.
  """

  @doc """
  Runs a command through `ctx.runner`, logging its output a line at a
  time (each through `mapper`; nil drops the line). A tool that couldn't
  be run, or ran past `:timeout`, is an error message; `:label` names it
  there (`:timed_out` is the whole message for the timeout, when the
  command is one step of something longer).
  """
  @spec run(map(), String.t(), [String.t()], keyword(), (String.t() -> String.t() | nil)) ::
          {:ok, ForemanAgent.Runner.result()} | {:error, String.t()}
  def run(ctx, command, args, opts, mapper \\ & &1) do
    case run_lines(ctx, command, args, opts, mapper) do
      {:ok, %{status: :timeout}} ->
        {:error,
         opts[:timed_out] || timed_out(opts[:label] || Path.basename(command), opts[:timeout])}

      {:ok, result} ->
        {:ok, result}

      {:error, {:not_found, command}} ->
        {:error, "#{command} is not installed on this box"}

      {:error, reason} ->
        {:error, "couldn't run #{command}: #{inspect(reason)}"}
    end
  end

  # Runs a command, re-chunking its output into lines. Each line goes
  # through `mapper` (nil drops it) to the operation log.
  defp run_lines(ctx, command, args, opts, mapper) do
    key = {__MODULE__, :pending, make_ref()}
    spinner = {__MODULE__, :spinner, make_ref()}

    emit = fn lines ->
      {texts, last} = log_lines(lines, mapper, Process.get(spinner))
      Process.put(spinner, last)

      for text <- texts do
        ctx.log.("info", if(String.ends_with?(text, "\n"), do: text, else: text <> "\n"))
      end
    end

    on_output = fn chunk ->
      parts = String.split(Process.get(key, "") <> chunk, "\n")
      Process.put(key, List.last(parts))
      emit.(Enum.drop(parts, -1))
      :ok
    end

    try do
      ctx.runner.run(
        command,
        args,
        opts |> Keyword.drop([:label, :timed_out]) |> Keyword.put(:on_output, on_output)
      )
    after
      case Process.delete(key) do
        rest when is_binary(rest) and rest != "" -> emit.([rest])
        _ -> :ok
      end

      Process.delete(spinner)
    end
  end

  # What the operation log shows for lines of a command's output: each
  # line through `mapper` (nil drops it), split into the lines it shows,
  # without colors or cursor movement. Lines that were only cursor
  # movement go, and so do spinner frames that redraw the one before
  # (clack and ora print one every 80 ms). `last` is the kept spinner
  # line's text, carried across chunks.
  defp log_lines(lines, mapper, last) do
    Enum.flat_map_reduce(lines, last, fn line, last ->
      case mapper.(line) do
        text when is_binary(text) -> text |> shown_lines() |> Enum.flat_map_reduce(last, &frame/2)
        _ -> {[], last}
      end
    end)
  end

  defp shown_lines(text) do
    lines = String.split(text, "\n")
    if String.ends_with?(text, "\n"), do: Enum.drop(lines, -1), else: lines
  end

  defp frame(line, last) do
    clean = line |> redrawn() |> strip_ansi()

    if blank?(clean) and String.contains?(line, ["\e", "\r"]) do
      {[], last}
    else
      case spinner_text(clean) do
        nil -> {[clean], nil}
        ^last -> {[], last}
        spinner -> {[clean], spinner}
      end
    end
  end

  # What's left on a line a CLI keeps redrawing (a progress count, a
  # spinner): the last text written after a return to the first column.
  # A return on its own erases nothing; an erase after it clears the line.
  @column_one ~r/\r|\e\[[01]?G/
  @erase ~r/\e\[[02]?[JK]/
  defp redrawn(line) do
    @column_one
    |> Regex.split(line)
    |> Enum.reverse()
    |> Enum.find("", &(not blank?(strip_ansi(&1)) or Regex.match?(@erase, &1)))
  end

  defp blank?(text), do: String.trim(text) == ""

  # A line that starts with a spinner frame, as the text after it with any
  # animated trailing dots left off.
  @spinner ~r/^\s*[\x{2800}-\x{28FF}◐◓◑◒◴◷◶◵◰◳◲◱◢◣◤◥◜◠◝◞◡◟▖▘▝▗✶✷✸✹✺]+\s+(.*?)[.…]*\s*$/u
  defp spinner_text(text) do
    case Regex.run(@spinner, text) do
      [_, rest] -> rest
      nil -> nil
    end
  end

  @doc "What a command that ran past its timeout is reported as."
  def timed_out(label, timeout),
    do: "#{label} timed out after #{div(timeout || 0, 60_000)} minutes and was stopped"

  # Colors and cursor movement from CLIs, which a log view can't use.
  @ansi ~r/\e\[[0-9;?]*[ -\/]*[@-~]|\e\][^\a\e]*(\a|\e\\)|\r(?!\n)/
  defp strip_ansi(text), do: Regex.replace(@ansi, text, "")

  @doc "All of a command's output as the operation log shows it."
  def shown(output) do
    {texts, _} = log_lines(String.split(String.trim_trailing(output, "\n"), "\n"), & &1, nil)
    Enum.join(texts, "\n")
  end

  @doc "The end of a command's output as the operation log shows it."
  def last_lines(output, mapper \\ & &1) do
    {texts, _} = log_lines(String.split(output, "\n"), mapper, nil)

    texts
    |> Enum.reject(&blank?/1)
    |> Enum.take(-15)
    |> Enum.join("\n")
  end
end
