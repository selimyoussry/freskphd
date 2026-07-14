defmodule FreskphdWeb.FreskHomeLive do
  @moduledoc """
  Lists fresks and hosts the new/edit modals (image upload + metadata).
  """
  use FreskphdWeb, :live_view

  alias Freskphd.Fresks
  alias Freskphd.Detection

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket),
      do: Phoenix.PubSub.subscribe(Freskphd.PubSub, Detection.index_topic())

    socket =
      socket
      |> assign(page_title: "Fresks")
      |> allow_upload(:fresk_image,
        accept: ~w(.png .jpg .jpeg),
        max_entries: 1,
        max_file_size: 60_000_000
      )
      |> load_fresks()

    {:ok, socket}
  end

  @impl true
  def handle_info({:fresk_updated, _id}, socket), do: {:noreply, load_fresks(socket)}

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, form: to_form(%{}, as: :fresk), fresk: nil)
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(page_title: "New fresk", fresk: nil)
    |> assign(form: to_form(%{"dt" => Date.to_iso8601(Date.utc_today())}, as: :fresk))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    fresk = Fresks.get_fresk!(id)

    socket
    |> assign(page_title: "Edit fresk", fresk: fresk)
    |> assign(
      form:
        to_form(
          %{"title" => fresk.title, "description" => fresk.description, "dt" => fresk.dt},
          as: :fresk
        )
    )
  end

  @impl true
  def handle_event("validate", %{"fresk" => params}, socket) do
    {:noreply, assign(socket, form: to_form(params, as: :fresk))}
  end

  def handle_event("new-fresk:submit", %{"fresk" => params}, socket) do
    uploaded =
      consume_uploaded_entries(socket, :fresk_image, fn %{path: path}, entry ->
        {:ok, {File.read!(path), entry.client_type || "image/png"}}
      end)

    case uploaded do
      [] ->
        {:noreply, put_flash(socket, :error, "Please upload a fresk image.")}

      [{bytes, content_type} | _] ->
        {:ok, fresk} =
          Fresks.create_fresk_with_image(params, %{data: bytes, content_type: content_type})

        Detection.detect_async(fresk)

        {:noreply,
         socket
         |> put_flash(:info, "Fresk uploaded. Detecting cards and arrows…")
         |> push_navigate(to: ~p"/")}
    end
  end

  def handle_event("edit-fresk:submit", %{"fresk" => params}, socket) do
    {:ok, _fresk} = Fresks.update_fresk(socket.assigns.fresk, params)

    {:noreply,
     socket
     |> put_flash(:info, "Fresk updated.")
     |> push_navigate(to: ~p"/")}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    id |> Fresks.get_fresk!() |> Fresks.delete_fresk()
    {:noreply, load_fresks(socket)}
  end

  defp load_fresks(socket) do
    fresks =
      Enum.map(Fresks.list_fresks(), fn fresk ->
        cards = Enum.count(fresk.annotations, &(&1.type == "card"))
        links = fresk.annotations |> Enum.flat_map(& &1.links) |> length()
        %{fresk: fresk, cards: cards, links: links}
      end)

    assign(socket, fresks: fresks)
  end

  defp status_badge("pending"), do: "badge-ghost"
  defp status_badge("processing"), do: "badge-warning"
  defp status_badge("review"), do: "badge-info"
  defp status_badge("validated"), do: "badge-success"
  defp status_badge("failed"), do: "badge-error"
  defp status_badge(_), do: "badge-ghost"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex items-center justify-between">
        <.header>
          Fresks
          <:subtitle>
            Upload a fresk — cards, sections and arrows are detected automatically, then you review.
          </:subtitle>
        </.header>
        <div class="flex items-center gap-2">
          <a href={~p"/export.xlsx"} class="btn btn-soft btn-sm">
            <.icon name="hero-arrow-down-tray" class="size-4" /> Export as XLSX
          </a>
          <.link navigate={~p"/fresks/new"} class="btn btn-primary btn-sm">
            <.icon name="hero-plus" class="size-4" /> New fresk
          </.link>
        </div>
      </div>

      <div
        :if={@fresks == []}
        class="rounded-lg border border-dashed border-base-300 p-10 text-center text-base-content/60"
      >
        No fresk yet. Click <span class="font-semibold">New fresk</span> to upload one.
      </div>

      <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
        <div
          :for={%{fresk: fresk, cards: cards, links: links} <- @fresks}
          class="group relative flex flex-col overflow-hidden rounded-xl border border-base-300 bg-base-100 transition hover:shadow-md"
        >
          <.link navigate={~p"/fresks/#{fresk.id}"} class="flex flex-col">
            <div class="relative aspect-video overflow-hidden bg-base-200">
              <img
                src={~p"/fresks/#{fresk.id}/image/display"}
                loading="lazy"
                class="h-full w-full object-contain"
              />
              <span class={["badge badge-sm absolute left-2 top-2", status_badge(fresk.status)]}>
                <span
                  :if={fresk.status == "processing"}
                  class="loading loading-spinner loading-xs mr-1"
                >
                </span>
                {fresk.status}
              </span>
            </div>
            <div class="p-3">
              <div class="truncate font-semibold" title={fresk.title}>{fresk.title}</div>
              <div class="mt-0.5 flex items-center gap-2 text-xs text-base-content/50">
                <span>{fresk.dt}</span>
                <span>·</span>
                <span>{cards} cards</span>
                <span>·</span>
                <span>{links} arrows</span>
              </div>
            </div>
          </.link>
          <div class="absolute right-2 top-2 flex items-center gap-1 opacity-0 transition group-hover:opacity-100">
            <.link
              navigate={~p"/fresks/#{fresk.id}/edit"}
              class="btn btn-circle btn-xs bg-base-100/90"
            >
              <.icon name="hero-pencil-square" class="size-3.5" />
            </.link>
            <button
              class="btn btn-circle btn-xs bg-base-100/90 text-error"
              phx-click="delete"
              phx-value-id={fresk.id}
              data-confirm="Delete this fresk and all its annotations?"
            >
              <.icon name="hero-trash" class="size-3.5" />
            </button>
          </div>
        </div>
      </div>

      <.modal :if={@live_action == :new} return_to={~p"/"} title="New fresk">
        <.form for={@form} phx-change="validate" phx-submit="new-fresk:submit" id="new-fresk-form">
          <.input field={@form[:title]} type="text" label="Title" required />
          <.input field={@form[:description]} type="textarea" label="Description" />
          <.input field={@form[:dt]} type="date" label="Date" required />

          <div class="mt-4">
            <label class="text-sm font-semibold">Fresk image</label>
            <div
              class="mt-1 rounded-lg border-2 border-dashed border-base-300 p-4"
              phx-drop-target={@uploads.fresk_image.ref}
            >
              <.live_file_input upload={@uploads.fresk_image} />
              <div :for={entry <- @uploads.fresk_image.entries} class="mt-2">
                <.live_img_preview entry={entry} class="max-h-40 rounded" />
                <div class="text-xs text-base-content/60">{entry.client_name}</div>
                <div
                  :for={err <- upload_errors(@uploads.fresk_image, entry)}
                  class="text-xs text-error"
                >
                  {error_to_string(err)}
                </div>
              </div>
            </div>
          </div>

          <div class="mt-6 flex justify-end">
            <.button type="submit" variant="primary" phx-disable-with="Uploading...">Save</.button>
          </div>
        </.form>
      </.modal>

      <.modal :if={@live_action == :edit} return_to={~p"/"} title="Edit fresk">
        <.form for={@form} phx-submit="edit-fresk:submit" id="edit-fresk-form">
          <.input field={@form[:title]} type="text" label="Title" required />
          <.input field={@form[:description]} type="textarea" label="Description" />
          <.input field={@form[:dt]} type="date" label="Date" required />
          <div class="mt-6 flex justify-end">
            <.button type="submit" variant="primary" phx-disable-with="Saving...">Save</.button>
          </div>
        </.form>
      </.modal>
    </Layouts.app>
    """
  end

  defp error_to_string(:too_large), do: "File is too large (max 60 MB)."
  defp error_to_string(:not_accepted), do: "Only PNG and JPEG images are accepted."
  defp error_to_string(:too_many_files), do: "Only one image can be uploaded."
  defp error_to_string(other), do: to_string(other)
end
