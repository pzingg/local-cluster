defmodule LocalCluster do
  @moduledoc """
  Easy local cluster handling for Elixir.

  From: https://github.com/whitfin/local-cluster

  This library is a utility library to offer easier testing of distributed
  clusters for Elixir. It offers very minimal shimming above several built
  in Erlang features to provide seamless node creations, especially useful
  when testing distributed applications.
  """

  require Logger

  @doc """
  Starts the current node as a distributed node.
  """
  @spec start :: :ok
  def start do
    # boot server startup
    start_boot_server = fn ->
      # voodoo flag to generate a "started" atom flag
      :global_flags.once("local_cluster:started", fn ->
        {:ok, _} =
          :erl_boot_server.start([
            {127, 0, 0, 1}
          ])
      end)

      :ok
    end

    # only ever handle the :erl_boot_server on the initial startup
    case :net_kernel.start([:"manager@127.0.0.1"]) do
      # handle nodes that have already been started elsewhere
      {:error, {:already_started, _}} -> start_boot_server.()
      # handle the node being started
      {:ok, _} -> start_boot_server.()
      # pass anything else
      anything -> anything
    end
  end

  @doc """
  Starts a number of namespaced child nodes.

  This will start the current runtime environment on a set of child nodes
  and return the names of the nodes to the user for further use. All child
  nodes are linked to the current process, and so will terminate when the
  parent process does for automatic cleanup.

  prefix - the string to prefix the index number for each node when creating each
    slave node's short name (e.g. "prefix1", "prefix2", etc.)

  amount - the number of slave nodes to create and start

  options
    :include_loaded_applications - true if all the loaded applications from the master
      node will be started on each slave node (default is true)
    :extra_applications - (optional) a list of atoms of applications that should be
      started on each slave node
    :files - (optional) a list of module source file paths that will be compiled and loaded
      into each slave node
    :put_app_env - (optional) a 2-arity function that takes the slave node's
      1-based index number and the started node name (an atom) as arguments,
      and returns a list of {module, func, args} tuples that will be called on the node
      prior to starting any applications in the node. Typically the mfa-tuples will
      be {Application, :put_env, args}
  """
  @spec start_nodes(binary, integer, Keyword.t()) :: [atom]
  def start_nodes(prefix, amount, options \\ [])
      when (is_binary(prefix) or is_atom(prefix)) and is_integer(amount) do
    node_list =
      Enum.map(1..amount, fn idx ->
        sname = "#{prefix}#{idx}"

        {:ok, name} =
          :slave.start_link(
            '127.0.0.1',
            String.to_atom(sname),
            '-loader inet -hosts 127.0.0.1 -setcookie \'#{:erlang.get_cookie()}\''
          )

        {idx, name}
      end)

    nodes = Enum.map(node_list, &elem(&1, 1))

    rpc = &({_, []} = :rpc.multicall(nodes, &1, &2, &3))

    rpc.(:code, :add_paths, [:code.get_path()])

    rpc.(Application, :ensure_all_started, [:mix])
    rpc.(Application, :ensure_all_started, [:logger])

    rpc.(Logger, :configure, level: Logger.level())
    rpc.(Mix, :env, [Mix.env()])

    extra_apps = Keyword.get(options, :extra_applications, [])

    apps_to_start =
      if Keyword.get(options, :include_loaded_applications, true) do
        Application.loaded_applications()
        |> Enum.map(fn {app_name, _, _} -> app_name end)
        |> Enum.concat(extra_apps)
      else
        extra_apps
      end

    # _ = Logger.debug("preparing #{inspect(apps_to_start)} on ALL nodes")

    # Copy application environments
    for app_name <- apps_to_start do
      for {key, val} <- Application.get_all_env(app_name) do
        rpc.(Application, :put_env, [app_name, key, val])
      end
    end

    # Optionally set per-node environments
    case Keyword.get(options, :put_app_env) do
      func when is_function(func, 2) ->
        for {idx, node} <- node_list do
          for mfa <- func.(idx, node) do
            case mfa do
              {m, f, a} when is_atom(m) and is_atom(f) and is_list(a) ->
                # _ = Logger.debug("calling #{inspect({m, f, a})} on node #{node}")

                :rpc.call(node, m, f, a)

              _ ->
                _ = Logger.error("put_app_env func did not return an MFA")

                {:error, :not_mfa}
            end
          end
        end

        :ok

      _ ->
        _ = Logger.error("put_app_env option should be a 2-arity func")

        {:error, :not_arity_2_function}
    end

    # Start applications
    # _ = Logger.debug("ensure_all_started #{inspect(apps_to_start)} on ALL nodes")

    rpc.(Application, :ensure_all_started, apps_to_start)

    for file <- Keyword.get(options, :files, []) do
      {:ok, source} = File.read(file)

      for {module, binary} <- Code.compile_string(source, file) do
        rpc.(:code, :load_binary, [
          module,
          :unicode.characters_to_list(file),
          binary
        ])
      end
    end

    nodes
  end

  @doc """
  Stops a set of child nodes.
  """
  @spec stop_nodes([atom]) :: :ok
  def stop_nodes(nodes) when is_list(nodes), do: Enum.each(nodes, &:slave.stop/1)

  @doc """
  Stops the current distributed node and turns it back into a local node.
  """
  @spec stop :: :ok | {:error, atom}
  def stop, do: :net_kernel.stop()

  @doc """
  Override just part of a an application environment with the value.
  Takes the same opts as Application.put_env/4.
  """
  def merge_app_env(app, key, value, opts \\ [])

  def merge_app_env(app, key, value, opts) when is_list(value) do
    new_value =
      case Application.get_env(app, key) do
        key when is_atom(key) ->
          Keyword.merge([{key, true}], value)

        keywords when is_list(keywords) ->
          Keyword.merge(keywords, value)

        _ ->
          value
      end

    # _ = Logger.debug("merged env for app #{app} key #{key} -> #{inspect(new_value)}")

    Application.put_env(app, key, new_value, opts)
  end

  def merge_app_env(app, key, value, opts) do
    Application.put_env(app, key, value, opts)
  end
end
