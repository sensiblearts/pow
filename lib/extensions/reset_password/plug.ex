defmodule PowResetPassword.Plug do
  @moduledoc """
  Plug helper methods.
  """
  alias Plug.Conn
  alias Pow.{Config, Plug, Store.Backend.EtsCache, UUID}
  alias PowResetPassword.Ecto.Context, as: ResetPasswordContext
  alias PowResetPassword.{Ecto.Schema, Store.ResetTokenCache}

  @doc """
  Creates a changeset from the user fetched in the connection.
  """
  @spec change_user(Conn.t(), map()) :: map()
  def change_user(conn, params \\ %{}) do
    user = reset_password_user(conn) || user_struct(conn)

    Schema.reset_password_changeset(user, params)
  end

  defp user_struct(conn) do
    conn
    |> Plug.fetch_config()
    |> Config.user!()
    |> struct()
  end

  @doc """
  Assigns a `:reset_password_user` key with the user in the connection.
  """
  @spec assign_reset_password_user(Conn.t(), map()) :: Conn.t()
  def assign_reset_password_user(conn, user) do
    Conn.assign(conn, :reset_password_user, user)
  end

  @doc """
  Finds a user for the provided params, creates a token, and stores the user
  for the token.
  """
  @spec create_reset_token(Conn.t(), map()) :: {:ok, map(), Conn.t()} | {:error, map(), Conn.t()}
  def create_reset_token(conn, params) do
    config = Plug.fetch_config(conn)
    user   =
      params
      |> Map.get("email")
      |> ResetPasswordContext.get_by_email(config)

    maybe_create_reset_token(conn, user, config)
  end

  defp maybe_create_reset_token(conn, nil, _config) do
    changeset = change_user(conn)
    {:error, %{changeset | action: :update}, conn}
  end
  defp maybe_create_reset_token(conn, user, config) do
    token = UUID.generate()
    {store, store_config} = store(config)

    store.put(store_config, token, user)

    {:ok, %{token: token, user: user}, conn}
  end

  @doc """
  Fetches user from the store by the provided token.
  """
  @spec user_from_token(Conn.t(), binary()) :: map() | nil
  def user_from_token(conn, token) do
    {store, store_config} =
      conn
      |> Plug.fetch_config()
      |> store()

    store_config
    |> store.get(token)
    |> case do
      :not_found -> nil
      user       -> user
    end
  end

  @doc """
  Updates the password for the user fetched in the connection.
  """
  @spec update_user_password(Conn.t(), map()) :: {:ok, map(), Conn.t()} | {:error, map(), Conn.t()}
  def update_user_password(conn, params) do
    config = Plug.fetch_config(conn)
    token  = conn.params["id"]

    conn
    |> reset_password_user()
    |> ResetPasswordContext.update_password(params, config)
    |> maybe_expire_token(conn, token, config)
  end

  defp maybe_expire_token({:ok, user}, conn, token, config) do
    expire_token(token, config)

    {:ok, user, conn}
  end
  defp maybe_expire_token({:error, changeset}, conn, _token, _config) do
    {:error, changeset, conn}
  end

  defp expire_token(token, config) do
    {store, store_config} = store(config)
    store.delete(store_config, token)
  end

  defp reset_password_user(conn) do
    conn.assigns[:reset_password_user]
  end

  defp store(config) do
    backend = Config.get(config, :cache_store_backend, EtsCache)

    {ResetTokenCache, [backend: backend]}
  end
end
