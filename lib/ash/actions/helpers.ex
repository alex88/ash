defmodule Ash.Actions.Helpers do
  @moduledoc false
  require Logger

  def validate_calculation_load!(%Ash.Query{}, module) do
    raise """
    `#{inspect(module)}.load/3` returned a query.

    Returning a query from the `load/3` callback of a calculation is now deprecated.
    Instead, return the load statement itself, i.e instead of `Ash.Query.load(query, [...])`,
    just return `[...]`. This is so that Ash can examine the requirements of just this single
    calculation to ensure that all required values are present
    """
  end

  def validate_calculation_load!(other, _), do: other

  defp set_context(%Ash.Changeset{} = changeset, context),
    do: Ash.Changeset.set_context(changeset, context)

  defp set_context(%Ash.Query{} = query, context), do: Ash.Query.set_context(query, context)

  def add_process_context(api, query_or_changeset, opts) do
    query_or_changeset = set_context(query_or_changeset, opts[:context] || %{})
    api = api || query_or_changeset.api

    opts =
      case query_or_changeset.context do
        %{
          private: %{
            actor: actor
          }
        } ->
          Keyword.put_new(opts, :actor, actor)

        _ ->
          opts
      end

    opts =
      case query_or_changeset.context do
        %{
          private: %{
            authorize?: authorize?
          }
        } ->
          Keyword.put_new(opts, :authorize?, authorize?)

        _ ->
          opts
      end

    opts =
      case query_or_changeset.context do
        %{
          private: %{
            tracer: tracer
          }
        } ->
          Keyword.put_new(opts, :tracer, tracer)

        _ ->
          opts
      end

    opts = opts |> add_actor(api) |> add_authorize?(api) |> add_tenant() |> add_tracer()

    query_or_changeset = add_context(query_or_changeset, opts)

    {query_or_changeset, opts}
  end

  defp add_context(query_or_changeset, opts) do
    context = Process.get(:ash_context, %{}) || %{}
    private_context = Map.new(Keyword.take(opts, [:actor, :authorize?]))

    case query_or_changeset do
      %Ash.Query{} ->
        query_or_changeset
        |> Ash.Query.set_context(context)
        |> Ash.Query.set_context(%{private: private_context})

      %Ash.Changeset{} ->
        query_or_changeset
        |> Ash.Changeset.set_context(context)
        |> Ash.Changeset.set_context(%{
          private: private_context
        })
    end
  end

  defp add_actor(opts, api) do
    opts =
      if Keyword.has_key?(opts, :actor) do
        opts
      else
        case Process.get(:ash_actor) do
          {:actor, value} ->
            Keyword.put(opts, :actor, value)

          _ ->
            opts
        end
      end

    if api do
      if !Keyword.has_key?(opts, :actor) && Ash.Api.Info.require_actor?(api) do
        raise Ash.Error.Forbidden.ApiRequiresActor, api: api
      end

      opts
    else
      # The only time api would be nil here is when we call this helper inside of `Changeset.for_*` and `Query.for_read`
      # meaning this will be run again later with the api, so we skip the validations on the api
      opts
    end
  end

  defp add_authorize?(opts, api) do
    opts =
      if Keyword.has_key?(opts, :authorize?) do
        opts
      else
        case Process.get(:ash_authorize?) do
          {:authorize?, value} ->
            Keyword.put(opts, :authorize?, value)

          _ ->
            opts
        end
      end

    if api do
      case Ash.Api.Info.authorize(api) do
        :always ->
          Keyword.put(opts, :authorize?, true)

        :by_default ->
          Keyword.put_new(opts, :authorize?, true)

        :when_requested ->
          if Keyword.has_key?(opts, :actor) do
            Keyword.put_new(opts, :authorize?, true)
          else
            opts
          end
      end
    else
      # The only time api would be nil here is when we call this helper inside of `Changeset.for_*` and `Query.for_read`
      # meaning this will be run again later with the api, so we skip the validations on the api
      opts
    end
  end

  defp add_tenant(opts) do
    if Keyword.has_key?(opts, :tenant) do
      opts
    else
      case Process.get(:ash_tenant) do
        {:tenant, value} ->
          Keyword.put(opts, :tenant, value)

        _ ->
          opts
      end
    end
  end

  defp add_tracer(opts) do
    if Keyword.has_key?(opts, :tracer) do
      opts
    else
      case Process.get(:ash_tracer) do
        {:tracer, value} ->
          Keyword.put(opts, :tracer, value)

        _ ->
          case Application.get_env(:ash, :tracer) do
            nil ->
              opts

            tracer ->
              Keyword.put(opts, :tracer, tracer)
          end
      end
    end
  end

  def warn_missed!(resource, action, result) do
    case Map.get(result, :resource_notifications, []) do
      empty when empty in [nil, []] ->
        :ok

      missed ->
        case Application.get_env(:ash, :missed_notifications, :ignore) do
          :ignore ->
            :ok

          :raise ->
            raise """
            Missed #{Enum.count(missed)} notifications in action #{inspect(resource)}.#{action.name}.

            This happens when the resources are in a transaction, and you did not pass
            `return_notifications?: true`. If you are in a changeset hook, you can
            return the notifications. If not, you can send the notifications using
            `Ash.Notifier.notify/1` once your resources are out of a transaction.
            """

          :warn ->
            {:current_stacktrace, stacktrace} = Process.info(self(), :current_stacktrace)

            Logger.warn("""
            Missed #{Enum.count(missed)} notifications in action #{inspect(resource)}.#{action.name}.

            This happens when the resources are in a transaction, and you did not pass
            `return_notifications?: true`. If you are in a changeset hook, you can
            return the notifications. If not, you can send the notifications using
            `Ash.Notifier.notify/1` once your resources are out of a transaction.

            #{Exception.format_stacktrace(stacktrace)}
            """)
        end
    end
  end

  def process_errors(changeset, [error]) do
    %{changeset | errors: []}
    |> Ash.Changeset.add_error(error)
    |> Map.get(:errors)
    |> case do
      [error] ->
        error

      errors ->
        errors
    end
  end

  def process_errors(changeset, errors) when is_list(errors) do
    %{changeset | errors: []}
    |> Ash.Changeset.add_error(errors)
    |> Map.get(:errors)
  end

  def process_errors(changeset, error), do: process_errors(changeset, [error])

  def load_runtime_types({:ok, results}, query, attributes?) do
    load_runtime_types(results, query, attributes?)
  end

  def load_runtime_types({:error, error}, _query, _attributes?) do
    {:error, error}
  end

  def load_runtime_types(results, query, attributes?) when is_list(results) do
    attributes = runtime_attributes(query, attributes?)
    calcs = runtime_calculations(query)

    if Enum.empty?(attributes) && Enum.empty?(calcs) do
      {:ok, results}
    else
      Enum.reduce_while(results, {:ok, []}, fn result, {:ok, results} ->
        case do_load_runtime_types(result, attributes, calcs) do
          {:ok, result} ->
            {:cont, {:ok, [result | results]}}

          other ->
            {:halt, other}
        end
      end)
      |> case do
        {:ok, results} -> {:ok, Enum.reverse(results)}
        other -> other
      end
    end
  end

  def load_runtime_types(nil, _, _attributes?), do: {:ok, nil}

  def load_runtime_types(result, query, attributes?) do
    do_load_runtime_types(
      result,
      runtime_attributes(query, attributes?),
      runtime_calculations(query)
    )
  end

  defp runtime_attributes(query, true) do
    case query.select do
      nil ->
        Ash.Resource.Info.attributes(query.resource)

      select ->
        Enum.map(select, &Ash.Resource.Info.attribute(query.resource, &1))
    end
    |> Enum.reject(fn %{type: type, constraints: constraints} ->
      Ash.Type.cast_in_query?(type, constraints)
    end)
  end

  defp runtime_attributes(_, _), do: []

  defp runtime_calculations(query) do
    query.calculations
    |> Kernel.||(%{})
    |> Enum.reject(fn {_name, calc} ->
      constraints = Map.get(calc, :constraints, [])

      if function_exported?(Ash.Type, :cast_in_query?, 2) do
        Ash.Type.cast_in_query?(calc.type, constraints)
      else
        Ash.Type.cast_in_query?(calc.type)
      end
    end)
  end

  defp do_load_runtime_types(record, select, calculations) do
    select
    |> Enum.reduce_while({:ok, record}, fn attr, {:ok, record} ->
      case Ash.Type.cast_stored(attr.type, Map.get(record, attr.name), attr.constraints) do
        {:ok, value} ->
          {:cont, {:ok, Map.put(record, attr.name, value)}}

        other ->
          {:halt, other}
      end
    end)
    |> case do
      {:ok, record} ->
        Enum.reduce_while(calculations, {:ok, record}, fn {name, calc}, {:ok, record} ->
          case calc.load do
            nil ->
              case Ash.Type.cast_stored(
                     calc.type,
                     Map.get(record.calculations || %{}, calc.name),
                     Map.get(calc, :constraints, [])
                   ) do
                {:ok, value} ->
                  {:cont, {:ok, Map.update!(record, :calculations, &Map.put(&1, name, value))}}

                other ->
                  {:halt, other}
              end

            load ->
              case Ash.Type.cast_stored(
                     calc.type,
                     Map.get(record, load),
                     Map.get(calc, :constraints, [])
                   ) do
                {:ok, casted} ->
                  {:cont, {:ok, Map.put(record, load, casted)}}

                other ->
                  {:halt, other}
              end
          end
        end)

      other ->
        other
    end
  end

  def select({:ok, results}, query) do
    {:ok, select(results, query)}
  end

  def select({:error, error}, _query) do
    {:error, error}
  end

  def select(results, query) when is_list(results) do
    Enum.map(results, &select(&1, query))
  end

  def select(nil, _), do: nil

  def select(result, %{select: nil}) do
    result
  end

  def select(result, %{resource: resource, select: select}) do
    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.flat_map(fn attribute ->
      if attribute.always_select? || attribute.primary_key? || attribute.name in select do
        []
      else
        [attribute.name]
      end
    end)
    |> Enum.reduce(result, fn key, record ->
      Map.put(record, key, nil)
    end)
    |> Ash.Resource.put_metadata(:selected, select)
  end

  def attributes_to_select(%{select: nil, resource: resource}) do
    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.map(& &1.name)
  end

  def attributes_to_select(%{select: select, resource: resource}) do
    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.flat_map(fn attribute ->
      if attribute.always_select? || attribute.primary_key? || attribute.name in select do
        [attribute.name]
      else
        []
      end
    end)
  end
end
