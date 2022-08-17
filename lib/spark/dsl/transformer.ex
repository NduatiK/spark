defmodule Spark.Dsl.Transformer do
  @moduledoc """
  A transformer manipulates and/or validates the entire DSL state of a resource.

  It's `transform/2` takes a `map`, which is just the values/configurations at each point
  of the DSL. Don't manipulate it directly, if possible, instead use functions like
  `get_entities/3` and `replace_entity/5` to manipulate it.

  Use the `after?/1` and `before?/1` callbacks to ensure that your transformer
  runs either before or after some other transformer.

  Return `true` in `after_compile/0` to have the transformer run in an `after_compile` hook,
  but keep in mind that no modifications to the dsl structure will be retained, so there is no
  point in returning a new dsl structure from `transform/2` if `after_compile/0` is defined. Instead,
  simply return `:ok` or `{:error, error}`
  """
  @callback transform(map) ::
              :ok
              | {:ok, map}
              | {:error, term}
              | {:warn, map, String.t() | list(String.t())}
              | :halt
  @callback before?(module) :: boolean
  @callback after?(module) :: boolean
  @callback after_compile?() :: boolean

  defmacro __using__(_) do
    quote do
      @behaviour Spark.Dsl.Transformer

      def sort_after(transformers) do
        Stream.filter(transformers, &after?/1)
      end

      def sort_before(transformers) do
        Stream.filter(transformers, &before?/1)
      end

      def before?(_), do: false
      def after?(_), do: false
      def after_compile?, do: false

      defoverridable before?: 1, after?: 1, after_compile?: 0
    end
  end

  @doc """
  Saves a value into the dsl config with the given key.

  This can be used to precompute some information and cache it onto the resource,
  or simply store a computed value. It can later be retrieved with `Spark.Dsl.Extension.get_persisted/3`.
  """
  def persist(dsl, key, value) do
    Map.update(dsl, :persist, %{key => value}, &Map.put(&1, key, value))
  end

  @doc """
  Add a quoted expression to be evaluated in the DSL module's context.

  Use this *extremely sparingly*. It should almost never be necessary, unless building certain
  extensions that *require* the module in question to define a given function.

  What you likely want is either one of the DSL introspection functions, like `Spark.Dsl.Extension.get_entities/2`
  or `Spark.Dsl.Extension.get_opt/5)`. If you simply want to store a custom value that can be retrieved easily, or
  cache some precomputed information onto the resource, use `persist/3`.

  Provide the dsl state, bindings that should be unquote-able, and the quoted block
  to evaluate in the module. For example, if we wanted to support a `resource.primary_key()` function
  that would return the primary key (this is unnecessary, just an example), we might do this:

  ```elixir
  fields = the_primary_key_fields

  dsl_state =
    Transformer.eval(
      dsl_state,
      [fields: fields],
      quote do
        def primary_key() do
          unquote(fields)
        end
      end
    )
  ```
  """
  def eval(dsl, bindings, block) do
    to_eval = {block, bindings}

    Map.update(
      dsl,
      :eval,
      [to_eval],
      &[to_eval | &1]
    )
  end

  def get_persisted(dsl, key, default \\ nil) do
    dsl
    |> Map.get(:persist, %{})
    |> Map.get(key, default)
  end

  def build_entity!(extension, path, name, opts) do
    case build_entity(extension, path, name, opts) do
      {:ok, entity} ->
        entity

      {:error, error} ->
        if is_exception(error) do
          raise error
        else
          raise "Error building entity #{inspect(error)}"
        end
    end
  end

  def build_entity(extension, path, name, opts) do
    do_build_entity(extension.sections(), path, name, opts)
  end

  defp do_build_entity(sections, [section_name], name, opts) do
    section = Enum.find(sections, &(&1.name == section_name))
    entity = Enum.find(section.entities, &(&1.name == name))

    do_build(entity, opts)
  end

  defp do_build_entity(
         sections,
         [section_name, maybe_entity_name],
         maybe_nested_entity_name,
         opts
       ) do
    section = Enum.find(sections, &(&1.name == section_name))

    entity =
      if section do
        Enum.find(section.entities, &(&1.name == maybe_entity_name))
      end

    sub_entity =
      if entity do
        entity.entities
        |> Keyword.values()
        |> List.flatten()
        |> Enum.find(&(&1.name == maybe_nested_entity_name))
      end

    if sub_entity do
      do_build(sub_entity, opts)
    else
      do_build_entity(section.sections, [maybe_entity_name], maybe_nested_entity_name, opts)
    end
  end

  defp do_build_entity(sections, [section_name | rest], name, opts) do
    section = Enum.find(sections, &(&1.name == section_name))
    do_build_entity(section.sections, rest, name, opts)
  end

  defp do_build(entity, opts) do
    entity_names =
      entity.entities
      |> Kernel.||([])
      |> Keyword.keys()

    {entities, opts} = Keyword.split(opts, entity_names)

    case Spark.OptionsHelpers.validate(opts, entity.schema) do
      {:ok, opts} ->
        result = struct(struct(entity.target, opts), entities)
        Spark.Dsl.Entity.transform(entity.transform, result)

      {:error, error} ->
        {:error, error}
    end
  end

  def add_entity(dsl_state, path, entity, opts \\ []) do
    Map.update(dsl_state, path, %{entities: [entity], opts: []}, fn config ->
      Map.update(config, :entities, [entity], fn entities ->
        if (opts[:type] || :prepend) == :prepend do
          [entity | entities]
        else
          entities ++ [entity]
        end
      end)
    end)
  end

  def remove_entity(dsl_state, path, func) do
    Map.update(dsl_state, path, %{entities: [], opts: []}, fn config ->
      Map.update(config, :entities, [], fn entities ->
        Enum.reject(entities, func)
      end)
    end)
  end

  def get_entities(dsl_state, path) do
    dsl_state
    |> Map.get(path, %{entities: []})
    |> Map.get(:entities, [])
  end

  def get_option(dsl_state, path, option) do
    dsl_state
    |> Map.get(path, %{opts: []})
    |> Map.get(:opts)
    |> Kernel.||([])
    |> Keyword.get(option)
  end

  def set_option(dsl_state, path, option, value) do
    dsl_state
    |> Map.put_new(path, %{opts: []})
    |> Map.update!(path, fn existing_opts ->
      existing_opts
      |> Map.put_new(:opts, [])
      |> Map.update!(:opts, fn opts ->
        Keyword.put(opts, option, value)
      end)
    end)
  end

  def replace_entity(dsl_state, path, replacement, matcher) do
    Map.update(dsl_state, path, %{entities: [replacement], opts: []}, fn config ->
      Map.update(config, :entities, [replacement], fn entities ->
        replace_match(entities, replacement, matcher)
      end)
    end)
  end

  defp replace_match(entities, replacement, matcher) do
    Enum.map(entities, fn entity ->
      if matcher.(entity) do
        replacement
      else
        entity
      end
    end)
  end

  def sort(transformers) do
    {after_compile, transformers} = Enum.split_with(transformers, & &1.after_compile?())

    dependencies =
      transformers
      |> Stream.flat_map(fn module ->
        transformers = List.delete(transformers, module)

        afters =
          transformers
          |> module.sort_after()
          |> Stream.map(&{module, &1})

        befores =
          transformers
          |> module.sort_before()
          |> Stream.map(&{&1, module})

        Stream.concat(afters, befores)
      end)
      |> Enum.into(MapSet.new())

    reverse_dependencies =
      dependencies
      |> Stream.map(fn {l, r} -> {r, l} end)
      |> Enum.into(MapSet.new())

    conflicts = MapSet.intersection(dependencies, reverse_dependencies)
    dependencies = MapSet.difference(dependencies, conflicts)

    Graph.new(type: :directed)
    |> Graph.add_vertices(transformers)
    |> Graph.add_edges(dependencies)
    |> Graph.topsort()
    |> Enum.reverse(after_compile)
  end
end
