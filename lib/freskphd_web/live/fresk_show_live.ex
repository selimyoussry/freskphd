defmodule FreskphdWeb.FreskShowLive do
  @moduledoc """
  Review workspace for a detected fresk. Shows the display image on a pan/zoom
  canvas with the auto-detected cards, sections and arrows overlaid, and an
  inspector panel to correct them: edit text/type/color, move/resize/draw boxes,
  link boxes, delete, then validate.
  """
  use FreskphdWeb, :live_view

  alias Freskphd.{Detection, Fresks}
  alias Freskphd.Fresks.Link
  alias Freskphd.Repo

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    fresk = Fresks.get_fresk!(id)

    if connected?(socket),
      do: Phoenix.PubSub.subscribe(Freskphd.PubSub, Detection.topic(fresk.id))

    socket =
      socket
      |> assign(page_title: fresk.title, mode: "select", selected: nil, progress: nil)
      |> assign_fresk(fresk)
      |> push_canvas()

    {:ok, socket}
  end

  ## Detection progress

  @impl true
  def handle_info({:detection, stage, text}, socket) do
    fresk = Fresks.get_fresk!(socket.assigns.fresk.id)

    socket =
      socket
      |> assign_fresk(fresk)
      |> assign(progress: %{stage: stage, text: text})
      |> push_canvas()

    socket =
      case stage do
        :done -> socket |> assign(progress: nil) |> put_flash(:info, text)
        :failed -> socket |> assign(progress: nil) |> put_flash(:error, text)
        _ -> socket
      end

    {:noreply, socket}
  end

  ## Toolbar

  @impl true
  def handle_event("set-mode", %{"mode" => mode}, socket) do
    {:noreply, socket |> assign(mode: mode) |> push_event("canvas:mode", %{mode: mode})}
  end

  def handle_event("rerun-detection", _params, socket) do
    Detection.detect_async(socket.assigns.fresk)

    {:noreply,
     socket
     |> assign_fresk(%{socket.assigns.fresk | status: "processing"})
     |> assign(progress: %{stage: :started, text: "Starting detection…"})}
  end

  def handle_event("validate-fresk", _params, socket) do
    {:ok, fresk} = Fresks.set_status(socket.assigns.fresk, "validated")

    {:noreply,
     socket |> assign_fresk(Fresks.get_fresk!(fresk.id)) |> put_flash(:info, "Fresk validated.")}
  end

  ## Selection (from canvas or the list)

  def handle_event("canvas:select", %{"id" => nil}, socket) do
    {:noreply, assign(socket, selected: nil)}
  end

  def handle_event("canvas:select", %{"id" => id}, socket) do
    {:noreply, select(socket, id)}
  end

  def handle_event("select-annotation", %{"id" => id}, socket) do
    id = to_int(id)
    {:noreply, select(socket, id) |> push_event("canvas:focus", %{id: id})}
  end

  ## Annotation edits from the canvas

  def handle_event("annotation:create", %{"type" => type} = p, socket) do
    fresk = socket.assigns.fresk

    {:ok, ann} =
      Fresks.create_annotation(%{
        "fresk_id" => fresk.id,
        "type" => type,
        "source" => "human",
        "status" => "validated",
        "fresk_width" => fresk.image_width || 1.0,
        "x1" => p["x1"],
        "y1" => p["y1"],
        "x2" => p["x2"],
        "y2" => p["y2"]
      })

    {:noreply, socket |> reload() |> select(ann.id) |> push_event("canvas:focus", %{id: ann.id})}
  end

  def handle_event("annotation:move", %{"id" => id} = p, socket) do
    ann = Fresks.get_annotation!(to_int(id))

    {:ok, _} =
      Fresks.update_annotation(ann, %{
        "x1" => p["x1"],
        "y1" => p["y1"],
        "x2" => p["x2"],
        "y2" => p["y2"],
        "source" => "human"
      })

    {:noreply, reload(socket)}
  end

  def handle_event("annotation:delete", %{"id" => id}, socket) do
    to_int(id) |> Fresks.get_annotation!() |> Fresks.delete_annotation()
    {:noreply, socket |> assign(selected: nil) |> reload()}
  end

  ## Inspector form

  def handle_event("annotation:save", %{"annotation" => params}, socket) do
    {:ok, _} =
      Fresks.update_annotation(
        socket.assigns.selected,
        Map.put(params, "source", "human")
      )

    {:noreply, socket |> reload() |> select(socket.assigns.selected.id)}
  end

  ## Links

  def handle_event("link:create", %{"source_id" => s, "target_id" => t}, socket) do
    {:ok, _} =
      Fresks.create_link(%{
        "source_annotation_id" => to_int(s),
        "target_annotation_id" => to_int(t),
        "origin" => "human"
      })

    {:noreply, reload(socket)}
  end

  def handle_event("link:update", %{"id" => id, "field" => field, "value" => value}, socket) do
    link = Fresks.get_link!(to_int(id))
    {:ok, _} = link |> Link.changeset(%{field => nilify(value)}) |> Repo.update()
    {:noreply, reload(socket)}
  end

  def handle_event("link:delete", %{"id" => id}, socket) do
    to_int(id) |> Fresks.get_link!() |> Fresks.delete_link()
    {:noreply, reload(socket)}
  end

  ## Helpers

  defp select(socket, id) do
    ann = Enum.find(socket.assigns.fresk.annotations, &(&1.id == to_int(id)))

    form =
      if ann,
        do:
          to_form(
            %{
              "type" => ann.type,
              "title" => ann.title || "",
              "category" => ann.category || "",
              "color" => ann.color || ""
            },
            as: :annotation
          )

    assign(socket, selected: ann, annotation_form: form)
  end

  defp reload(socket) do
    socket
    |> assign_fresk(Fresks.get_fresk!(socket.assigns.fresk.id))
    |> push_canvas()
  end

  defp assign_fresk(socket, fresk) do
    cards = Enum.filter(fresk.annotations, &(&1.type == "card"))
    sections = Enum.filter(fresk.annotations, &(&1.type == "section"))
    links = Enum.flat_map(fresk.annotations, & &1.links)
    ann_by_id = Map.new(fresk.annotations, &{&1.id, &1})

    assign(socket,
      fresk: fresk,
      cards: Enum.sort_by(cards, &String.downcase(&1.title || "~")),
      sections: sections,
      links: links,
      ann_by_id: ann_by_id
    )
  end

  defp push_canvas(socket) do
    if connected?(socket) do
      fresk = socket.assigns.fresk

      data =
        Map.merge(Fresks.canvas_data(fresk), %{
          image_url: ~p"/fresks/#{fresk.id}/image/display"
        })

      push_event(socket, "canvas:set", data)
    else
      socket
    end
  end

  defp to_int(i) when is_integer(i), do: i
  defp to_int(s) when is_binary(s), do: String.to_integer(s)

  defp nilify(""), do: nil
  defp nilify(v), do: v

  defp status_badge("pending"), do: "badge-ghost"
  defp status_badge("processing"), do: "badge-warning"
  defp status_badge("review"), do: "badge-info"
  defp status_badge("validated"), do: "badge-success"
  defp status_badge("failed"), do: "badge-error"
  defp status_badge(_), do: "badge-ghost"

  ## Render

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex items-center justify-between gap-4">
        <div class="flex items-center gap-3 min-w-0">
          <.link navigate={~p"/"} class="btn btn-ghost btn-sm btn-circle">
            <.icon name="hero-arrow-left" class="size-5" />
          </.link>
          <h1 class="text-xl font-semibold truncate">{@fresk.title}</h1>
          <span class={["badge badge-sm", status_badge(@fresk.status)]}>{@fresk.status}</span>
        </div>
        <div class="flex items-center gap-2 flex-shrink-0">
          <button class="btn btn-ghost btn-sm" phx-click="rerun-detection">
            <.icon name="hero-arrow-path" class="size-4" /> Re-detect
          </button>
          <button
            :if={@fresk.status != "validated"}
            class="btn btn-primary btn-sm"
            phx-click="validate-fresk"
          >
            <.icon name="hero-check-badge" class="size-4" /> Validate
          </button>
        </div>
      </div>

      <.progress_panel :if={@progress} progress={@progress} />

      <div class="flex gap-4 h-[calc(100vh-13rem)]">
        <div class="flex flex-1 flex-col gap-2 min-w-0">
          <div class="flex items-center gap-2 rounded-lg border border-base-300 bg-base-100 p-2">
            <div class="join">
              <.mode_button mode={@mode} value="select" icon="hero-cursor-arrow-rays" label="Select" />
              <.mode_button mode={@mode} value="card" icon="hero-square-2-stack" label="Card" />
              <.mode_button mode={@mode} value="section" icon="hero-rectangle-group" label="Section" />
              <.mode_button mode={@mode} value="link" icon="hero-arrow-long-right" label="Link" />
            </div>
            <span class="ml-auto text-xs text-base-content/50">
              scroll to zoom · drag to pan · Del to remove
            </span>
          </div>

          <div
            id="fresk-canvas"
            phx-hook="FreskCanvas"
            phx-update="ignore"
            class="relative flex-1 overflow-hidden rounded-lg border border-base-300 bg-base-200"
          >
            <canvas class="absolute inset-0 h-full w-full cursor-crosshair"></canvas>
          </div>
        </div>

        <aside class="flex w-80 flex-shrink-0 flex-col gap-4 overflow-y-auto">
          <.inspector :if={@selected} selected={@selected} form={@annotation_form} />

          <.stats cards={@cards} sections={@sections} links={@links} />

          <.section title={"Sections (#{length(@sections)})"}>
            <button
              :for={s <- @sections}
              class={[
                "flex w-full items-center gap-2 rounded p-1.5 text-left text-sm hover:bg-base-200",
                @selected && @selected.id == s.id && "bg-base-200 ring-1 ring-primary"
              ]}
              phx-click="select-annotation"
              phx-value-id={s.id}
            >
              <.icon name="hero-rectangle-group" class="size-4 text-base-content/40" />
              <span class="truncate flex-1">{s.title || "Untitled section"}</span>
            </button>
            <p :if={@sections == []} class="p-1.5 text-xs text-base-content/50">None detected.</p>
          </.section>

          <.section title={"Cards (#{length(@cards)})"}>
            <button
              :for={c <- @cards}
              class={[
                "flex w-full items-center gap-2 rounded p-1.5 text-left text-sm hover:bg-base-200",
                @selected && @selected.id == c.id && "bg-base-200 ring-1 ring-primary"
              ]}
              phx-click="select-annotation"
              phx-value-id={c.id}
            >
              <span
                class="size-3 flex-shrink-0 rounded-sm border border-base-300"
                style={"background:#{c.color}"}
              >
              </span>
              <span class="truncate flex-1">{c.title || "Untitled"}</span>
              <.icon
                :if={low_conf?(c)}
                name="hero-exclamation-triangle"
                class="size-3.5 text-warning"
              />
            </button>
          </.section>

          <.section title={"Arrows (#{length(@links)})"}>
            <div :for={l <- @links} class="flex items-center gap-2 rounded p-1.5 text-sm">
              <span
                class="size-3 flex-shrink-0 rounded-full border border-base-300"
                style={"background:#{l.color || "#111827"}"}
              >
              </span>
              <span class="badge badge-xs badge-ghost">{l.line_style || "?"}</span>
              <span class="truncate flex-1 text-xs">
                {link_label(@ann_by_id, l)}
              </span>
              <button
                class="btn btn-ghost btn-xs btn-circle text-error"
                phx-click="link:delete"
                phx-value-id={l.id}
              >
                <.icon name="hero-trash" class="size-3.5" />
              </button>
            </div>
            <p :if={@links == []} class="p-1.5 text-xs text-base-content/50">None detected.</p>
          </.section>
        </aside>
      </div>
    </Layouts.app>
    """
  end

  ## Function components

  @stage_labels [
    opencv: "OpenCV geometry",
    cards: "Card text",
    sections: "Section titles",
    arrows: "Arrow graph",
    saving: "Saving",
    done: "Done"
  ]
  @stage_order [:started | Enum.map(@stage_labels, &elem(&1, 0))]

  attr :progress, :map, required: true

  defp progress_panel(assigns) do
    assigns = assign(assigns, :labels, @stage_labels)

    ~H"""
    <div class="rounded-lg border border-info/40 bg-base-100 p-4">
      <div class="mb-3 flex items-center gap-2">
        <span class="loading loading-spinner loading-sm text-info"></span>
        <span class="font-medium">{@progress.text}</span>
      </div>
      <ol class="flex flex-wrap gap-x-5 gap-y-1">
        <li
          :for={{stage, label} <- @labels}
          class={[
            "flex items-center gap-1 text-xs",
            stage_state(stage, @progress.stage) == :done && "text-success",
            stage_state(stage, @progress.stage) == :active && "font-semibold text-info",
            stage_state(stage, @progress.stage) == :pending && "text-base-content/40"
          ]}
        >
          <.icon
            name={
              case stage_state(stage, @progress.stage) do
                :done -> "hero-check-circle-solid"
                :active -> "hero-arrow-path"
                :pending -> "hero-clock"
              end
            }
            class={["size-3.5", stage_state(stage, @progress.stage) == :active && "animate-spin"]}
          /> {label}
        </li>
      </ol>
    </div>
    """
  end

  defp stage_state(stage, current) do
    si = Enum.find_index(@stage_order, &(&1 == stage)) || 0
    ci = Enum.find_index(@stage_order, &(&1 == current)) || 0

    cond do
      current == :done -> :done
      si < ci -> :done
      si == ci -> :active
      true -> :pending
    end
  end

  attr :mode, :string, required: true
  attr :value, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true

  defp mode_button(assigns) do
    ~H"""
    <button
      class={["btn join-item btn-sm", @mode == @value && "btn-primary"]}
      phx-click="set-mode"
      phx-value-mode={@value}
    >
      <.icon name={@icon} class="size-4" /> {@label}
    </button>
    """
  end

  attr :selected, :map, required: true
  attr :form, :any, required: true

  defp inspector(assigns) do
    ~H"""
    <div class="rounded-lg border border-primary/40 bg-base-100 p-3">
      <div class="mb-2 flex items-center justify-between">
        <h3 class="text-sm font-semibold">Selected {@selected.type}</h3>
        <button
          class="btn btn-ghost btn-xs text-error"
          phx-click="annotation:delete"
          phx-value-id={@selected.id}
        >
          <.icon name="hero-trash" class="size-4" /> Delete
        </button>
      </div>
      <.form for={@form} phx-submit="annotation:save" class="flex flex-col gap-2">
        <.input
          field={@form[:type]}
          type="select"
          label="Type"
          options={[{"Card", "card"}, {"Section", "section"}]}
        />
        <.input field={@form[:title]} type="text" label="Text" />
        <.input field={@form[:category]} type="text" label="Category" />
        <div class="flex items-end gap-2">
          <div class="flex-1">
            <.input field={@form[:color]} type="text" label="Color (hex)" />
          </div>
          <span
            class="mb-1 size-8 rounded border border-base-300"
            style={"background:#{@selected.color}"}
          >
          </span>
        </div>
        <.button type="submit" variant="primary" class="btn-sm mt-1">Save</.button>
      </.form>
      <p :if={@selected.confidence} class="mt-2 text-xs text-base-content/50">
        detection confidence {round(@selected.confidence * 100)}% · {@selected.source}
      </p>
    </div>
    """
  end

  attr :cards, :list, required: true
  attr :sections, :list, required: true
  attr :links, :list, required: true

  defp stats(assigns) do
    ~H"""
    <div class="grid grid-cols-3 gap-2">
      <.stat_tile label="Cards" value={length(@cards)} />
      <.stat_tile label="Sections" value={length(@sections)} />
      <.stat_tile label="Arrows" value={length(@links)} />
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true

  defp stat_tile(assigns) do
    ~H"""
    <div class="rounded-lg border border-base-300 bg-base-100 p-2 text-center">
      <div class="text-lg font-semibold">{@value}</div>
      <div class="text-xs text-base-content/50">{@label}</div>
    </div>
    """
  end

  attr :title, :string, required: true
  slot :inner_block, required: true

  defp section(assigns) do
    ~H"""
    <div class="rounded-lg border border-base-300 bg-base-100 p-2">
      <h3 class="mb-1 px-1 text-xs font-semibold uppercase tracking-wide text-base-content/50">
        {@title}
      </h3>
      <div class="flex flex-col">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  defp low_conf?(%{confidence: c}) when is_float(c), do: c < 0.5
  defp low_conf?(_), do: false

  defp link_label(ann_by_id, link) do
    src = ann_by_id[link.source_annotation_id]
    tgt = ann_by_id[link.target_annotation_id]
    "#{title_of(src)} → #{title_of(tgt)}"
  end

  defp title_of(nil), do: "?"
  defp title_of(%{title: nil, type: type}), do: "(#{type})"
  defp title_of(%{title: title}), do: title
end
