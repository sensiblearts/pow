# Mnesia cache store backend

`Pow.Store.Backend.MnesiaCache` implements the behaviour declared in `Pow.Store.Base` to use Erlang's Mnesia database as the session cache.

The reaon you might use Mnesia is that, in a clustered situation, you need to enable distributed checking of Pow User sessions, regardless of which backend server is chosen (e.g., by a load balancer) to service a given http request. This stateless load balancing is possible because Mnesia, being a distributed database, can replicate the cache across all connected nodes. Hence, there is no need for stateful routing at the load balancer (a.k.a., no need for "sticky sessions"). However, there is a need to connect the nodes!

Connecting elixir nodes is straight forward, but the details can be complicated depending on the infrastructure strategy being used. For example, there is much more to learn if autoscaling or dynamic node discovery are requried. Although this is outside the scope of the current guide, near the end we provide some links to relevant documentation. 

This guide will first describe installation and configuration of Pow to use the Mnesia cache store. Then, a few use cases are described, along with considerations relative to Pow User sessions, in increasing order of complexity:

1. Simple loop to connect a pre-configured set of servers
2. Use of the libcluster `Cluster.Strategy.Epmd` strategy to connect a pre-configured set of servers
3. Use of the libcluster `Cluster.Strategy.ErlangHosts` strategy to read the list of servers from the `.hosts.erlang` file and connect then dynamically. 

## Configuring Pow to use Mnesia

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

Once configured, the next step is to connect the clustered nodes at run-time and pass the identity of these nodes to Mnesia via, Pow. The specifics of how this is done depends on the clustering stratgey.


## Connecting a pre-configured set of server nodes


Perhaps the most straightforward approach to a cluster is to hard-code the identity of each server in your elixir code; while not very flexible, it's easy to understand. So, in `application.ex` we will add code that will, when the app starts at run-time:

1. connect two servers, `a` and `b`, and then
2. add Mnesia to your supervision tree, as follows:

```elixir
  def start(_type, _args) do
  
    connect_nodes()

    children = [
      Gjwapp.Repo,
      GjwappWeb.Endpoint,
      {Pow.Store.Backend.MnesiaCache, extra_db_nodes: Node.list()}
    ] 
    opts = [strategy: :one_for_one, name: Gjwapp.Supervisor]
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
config :gjwapp, GjwappWeb.Endpoint,
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

## Using libcluster's Cluster.Strategy.Epmd strategy to connect a pre-configured set of servers

TODO

## Use of the libcluster's Cluster.Strategy.ErlangHosts to connect servers specified in the .hosts.erlang file 

TODO

## Test module

```elixir
# TODO: see redis guide

```

## Further reading

TODO