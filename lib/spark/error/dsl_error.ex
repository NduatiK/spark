defmodule Spark.Error.DslError do
  @moduledoc "Used when a DSL is incorrectly configured."
  defexception [:module, :message, :path]

  @type t :: %__MODULE__{
          __exception__: true,
          module: nil | module,
          message: String.t() | any,
          path: [:atom]
        }

  def message(%{module: module, message: message, path: blank})
      when is_nil(blank) or blank == [] do
    "[#{normalize_module_name(module)}]\n #{get_message(message)}"
  end

  def message(%{module: module, message: message, path: dsl_path}) do
    dsl_path = Enum.join(dsl_path, " -> ")
    "[#{normalize_module_name(module)}]\n #{dsl_path}:\n  #{get_message(message)}"
  end

  defp normalize_module_name(module) do
    inspect(module)
  end

  defp get_message(message) when is_exception(message) do
    Exception.format(:error, message)
  end

  defp get_message(message) when is_binary(message) do
    message
  end

  defp get_message(message) do
    inspect(message)
  end
end
