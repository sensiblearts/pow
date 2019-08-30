# Mnesia cache store backend

`Pow.Store.Backend.MnesiaCache` implements the behaviour declared in `Pow.Store.Base` to use Erlang's Mnesia database as the session cache.

The reason you might use Mnesia is that, in a clustered situation, you need to enable distributed checking of Pow User sessions, regardless of which backend server is chosen (e.g., by a load balancer) to service a given http request. This stateless load balancing is possible because Mnesia, being a distributed database, can replicate the cache across all connected nodes. Hence, there is no need for stateful routing at the load balancer (a.k.a., no need for "sticky sessions"). However, there is a need to connect the nodes!

Connecting elixir nodes is straight forward, but the details can be complicated depending on the infrastructure strategy being used. For example, there is much more to learn if autoscaling or dynamic node discovery are requried. Although this is outside the scope of the current guide, near the end we provide some links to relevant documentation. 

This guide will first describe installation and configuration of Pow to use the Mnesia cache store. Then, a few use cases are described, along with considerations relative to Pow User sessions, in increasing order of complexity:

1. Simple loop to connect a pre-configured set of servers
2. Use of the libcluster `Cluster.Strategy.Gossip` where all servers broadcast UDP messages over the same port to find one another; hence, no need to specify servers or the erlang short names
3. Use of the libcluster `Cluster.Strategy.ErlangHosts` strategy to read the list of server IPs or hostnames from the `.hosts.erlang` file and connect then dynamically; then, the servers automatically discover the erlang short names
4. Use of the libcluster `Cluster.Strategy.Epmd` strategy to connect a pre-configured set of servers and erlang node short names

## Configuring Pow to use Mnesia: Compile-time Configuration

Mnesia is part of OTP so there are no additional dependencies to add to `mix.exs`.

Depending on whether you are working in development or production mode, be sure that (in either `/config/dev.exs` or `/config/prod.exs`) you have specified an Mnesia storage location, such as:

```elixir
config :mnesia, dir: to_charlist(File.cwd!) ++ '/priv/mnesia'

```

and that you have configured Pow to use Mnesia:

```elixir
config :my_app, :pow,
  user: MyApp.Users.User,
  repo: MyApp.Repo,
  # ...
  cache_store_backend: Pow.Store.Backend.MnesiaCache
```

Also, you need to add :mnesia to :extra_applications in mix.exs to ensure that it's also included in the release; in `mix.exs`, specify:

``` elixir
  def application do
    [
      mod: {MyApp.Application, []},
      extra_applications: [:mnesia, ... ],
    ]
  end
```

## Configuring Pow to use Mnesia: Run-time Configuration

While the above code applies the configuration information needed at compile time, we typically will want to supply information about the distributed nodes at run time, when the applicatino starts; hence, in `application.ex` we will add code that will, when the app starts:

1. ensure that the elixir nodes are connected and then
2. add the Mnesia cache to your supervision tree

```elixir
  def start(_type, _args) do
  
    connect_nodes()

    children = [
      MyApp.Repo,
      MyAppWeb.Endpoint,
      {Pow.Store.Backend.MnesiaCache, extra_db_nodes: Node.list()}
    ] 
    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp connect_nodes() do
    # ensure that the elixir nodes are connected
  end

```

The above function `connect_nodes/0` is presented only to convey that you need to ensure that the nodes are connected -- that each elixir node participating in the cluster knows the identity of every other node in the cluster. There are various strategies that could be employed to ensure this is the case, but for now we will assume that the cluster is fully connected: each node in the cluster knows of the other nodes in the cluster. Once this is the case, the function `Node.list/0` called on _any node_ will return a list of nodes in the cluster; and as you can see above, this list is passed to Pow's MnesiaCache configuration with the key `:extra_db_nodes`.

When the application starts, if there are no other nodes available, `MnesiaCache` will attempt to load data that was previously persisted to disk; however, if a cluster _is_ running, then the mnesia cache data of those existing nodes will be loaded instead of the locally persisted data. Specifically, when your application starts it will initialize the `MnesiaCache` Generver, which starts the node's instance of mnesia and then connects to the other nodes in the cluster (internally, by calling `:mnesia.change_config/2`). Once connected to the other nodes (and their mnesia instances), the connecting node will make a remote procedure call to one of the other nodes (e.g., the one at the head of the list of the cluster nodes) to retrieve the mnesia table information. This table information is then used as a parameter when calling internally `:mnesia.add_table_copy/3`, which creates a local replicate of the cache table; or, does nothing if the table already exists.

## Adding or removing nodes at run time

As long as at least one node in the `:extra_db_nodes` list is connected to the cluster, the MnesiaCache instances for all other nodes will automatically be connected and replicated. This makes it very easy to join clusters, since you won't have to update the config on the old nodes at all. And as long as the old nodes connect to at least one node that's in the cluster when restarting, it'll automatically connect to the new node as well, even without updating the :extra_db_nodes setting.

## Recovery after network splits

A network split or "netsplit" can occur when any two nodes become disconnected, for any reason. The network will continue to operate e.g., as two _separate_ networks and the mnesia cache contents will diverge. If this happens, the system should 1) attempt to heal the split and then 2) ensure data integrity by making the caches consistent on all nodes. In `Pow` this responsibility is filled by `Pow.Store.Backend.MnesiaCache.Unsplit`. Specifically, `Unsplit` is a Genserver that listens to Mnesia for `:inconsistent_database` system events. `Unsplit` will find the oldest node and restore that node's table into all the partitioned nodes.

If you need to use `Unsplit` then you need to add it to your application `start/2` method as well:

```elixir
  def start(_type, _args) do
  
    children = [
      MyApp.Repo,
      MyAppWeb.Endpoint,
      {Pow.Store.Backend.MnesiaCache, extra_db_nodes: Node.list()},
      Pow.Store.Backend.MnesiaCache.Unsplit
    ] 
    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end

```
## Using other libraries that also use the Mnesia instance

**It's strongly recommended to take into account any libraries that will be using Mnesia for storage before using the `Unsplit` module.**

A common example would be a job queue, where a potential solution to prevent data loss is to simply keep the job queue table on only one server instead of replicating it among all nodes. If you do this, then when a network partition occurs, the job queue table can be excluded from the tables to be flushed (and restored) during healing by setting `:flush_tables` to `false` (the default). This way, the `Unsplit` module can self-heal without affecting the job queue table.


## Example: Connecting a hard-coded set of server nodes

Normally you would not hard-code the identify of the participating nodes, but this is easy to understand. So, in `application.ex` we will add code that will, when the app starts at run-time:

1. connect elixir nodes `a` and `b`
2. add the Mnesia cache to your supervision tree

```elixir
  def start(_type, _args) do
  
    connect_nodes()

    children = [
      MyApp.Repo,
      MyAppWeb.Endpoint,
      {Pow.Store.Backend.MnesiaCache, extra_db_nodes: Node.list()}
    ] 
    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp connect_nodes() do
    Enum.each(nodes(), fn(node) ->
      Node.connect(node)
    end)
  end

  defp nodes() do
    {:ok, hostname} = :inet.gethostname()
    for sname <- ["a", "b"], do:   :"#{sname}@#{hostname}" 
  end
```

IMPORTANT: If you are going to test the above code by launching two dev mode instances of e.g., `MIX_ENV=dev mix phx.server` on _the same machine_, then you need to make sure that they are simulating separate machines by specifying separate locations to store the Mnesia data. So you could launch the first instance with `/config/dev.exs` as specified (above) with the following command:

```
MIX_ENV=dev PORT=4000 elixir --sname a -S mix phx.server
```
(The `--sname` option passed to elixir/erlang assigns the `sname` (short name) of `a` to the server, such that the full name is `a@hostname`.)

Then, _before_ launching the second instance, specify a different storage location in `/config/dev.exs`; however, to prevent code reloading from confusing the two runtime instances of your app, you need to change it to false:

```elixir
config :myapp, MyAppWeb.Endpoint,
  # ...
  code_reloader: false,  # remember to change this back!
  # ...

config :mnesia, dir: to_charlist(File.cwd!) ++ '/priv/mnesia_2'

```

and then launch this second instance with the command:

```
MIX_ENV=dev PORT=4002 elixir --sname b -S mix phx.server

```

The above config and commands will result in the following:

| sname  | full name  | port  | Mnesia storage location  |
|---|---|---|---|
| a  | a@hostname  | 4000  | ./priv/mnesia  |
| b  | b@hostname  | 4002  | ./priv/mnesia_2  |


Now, if you run the above servers as backends with e.g., HAProxy or nginx as a round-robin load balancer, you will see that:
- Http requests are routed in a balanced way to the two backends.
- Node `b` accepts the session credentials that were created if sign-in occurred on node `a`, and vice versa
- you can kill and restart `a` or `b` without any downtime from the perspective of the browser session: When you restart a killed server Mnesia will re-sync the cached schema so that each backend node again has a copy of the current cache.

## Example: Using libcluster's Cluster.Strategy.Gossip strategy to discover servers dynamically

TODO

## Example: Use of the libcluster's Cluster.Strategy.ErlangHosts to connect servers specified in the .hosts.erlang file 

TODO

## Example: Using libcluster's Cluster.Strategy.Epmd strategy to connect a pre-configured set of servers

TODO

## Test module

```elixir
# TODO: see redis guide

```

## Further reading

TODO