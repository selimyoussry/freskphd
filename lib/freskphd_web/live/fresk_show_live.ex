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
      |> assign(
        page_title: fresk.title,
        mode: "select",
        selected: nil,
        selected_link: nil,
        progress: nil,
        layers: %{cards: true, sections: true, arrows: true},
        link_from: "card",
        link_to: "card",
        tab: "cards"
      )
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

  def handle_event("toggle-layer", %{"layer" => layer}, socket) do
    layers = Map.update!(socket.assigns.layers, String.to_existing_atom(layer), &(not &1))
    {:noreply, socket |> assign(layers: layers) |> push_event("canvas:layers", layers)}
  end

  def handle_event("set-link-endpoint", %{"which" => which, "type" => type}, socket) do
    socket = assign(socket, if(which == "from", do: :link_from, else: :link_to), type)

    {:noreply,
     push_event(socket, "canvas:link-endpoints", %{
       from: socket.assigns.link_from,
       to: socket.assigns.link_to
     })}
  end

  def handle_event("set-tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, tab: tab)}
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

  def handle_event("invalidate-fresk", _params, socket) do
    {:ok, fresk} = Fresks.set_status(socket.assigns.fresk, "review")

    {:noreply,
     socket
     |> assign_fresk(Fresks.get_fresk!(fresk.id))
     |> put_flash(:info, "Fresk moved back to review.")}
  end

  ## Selection (from canvas or the list)

  def handle_event("canvas:select", %{"id" => nil}, socket) do
    {:noreply, assign(socket, selected: nil, selected_link: nil)}
  end

  def handle_event("canvas:select", %{"id" => id}, socket) do
    {:noreply, select(socket, id)}
  end

  def handle_event("select-annotation", %{"id" => id}, socket) do
    id = to_int(id)
    {:noreply, select(socket, id) |> push_event("canvas:focus", %{id: id})}
  end

  ## Link selection (from canvas or the list)

  def handle_event("link:select", %{"id" => id}, socket) do
    {:noreply, select_link(socket, to_int(id))}
  end

  def handle_event("select-link", %{"id" => id}, socket) do
    id = to_int(id)
    {:noreply, select_link(socket, id) |> push_event("canvas:focus-link", %{id: id})}
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

    {:noreply,
     socket
     |> reload()
     |> select(ann.id)
     |> push_event("canvas:focus", %{id: ann.id})
     |> put_flash(:info, "#{String.capitalize(type)} added — set its title in the inspector.")}
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

  def handle_event("annotation:validate", %{"id" => id}, socket) do
    id = to_int(id)
    ann = Fresks.get_annotation!(id)
    status = if ann.status == "validated", do: "pending", else: "validated"
    {:ok, _} = Fresks.update_annotation(ann, %{"status" => status})

    socket = reload(socket)
    selected = socket.assigns.selected
    {:noreply, if(selected && selected.id == id, do: select(socket, id), else: socket)}
  end

  ## Inspector form

  def handle_event("annotation:save", %{"annotation" => params}, socket) do
    {:ok, _} =
      Fresks.update_annotation(
        socket.assigns.selected,
        Map.put(params, "source", "human")
      )

    {:noreply,
     socket |> reload() |> select(socket.assigns.selected.id) |> put_flash(:info, "Saved.")}
  end

  ## Links

  def handle_event("link:create", %{"source_id" => s, "target_id" => t}, socket) do
    {:ok, link} =
      Fresks.create_link(%{
        "source_annotation_id" => to_int(s),
        "target_annotation_id" => to_int(t),
        "origin" => "human"
      })

    {:noreply,
     socket
     |> reload()
     |> select_link(link.id)
     |> assign(tab: "arrows")
     |> put_flash(:info, "Arrow added.")}
  end

  def handle_event("link:update", %{"id" => id, "field" => field, "value" => value}, socket) do
    {:noreply, update_link(socket, to_int(id), field, value)}
  end

  def handle_event("link:delete", %{"id" => id}, socket) do
    to_int(id) |> Fresks.get_link!() |> Fresks.delete_link()
    {:noreply, socket |> assign(selected_link: nil) |> reload()}
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

    assign(socket, selected: ann, selected_link: nil, annotation_form: form)
  end

  defp select_link(socket, id) do
    link = Enum.find(socket.assigns.links, &(&1.id == id))
    assign(socket, selected_link: link, selected: nil)
  end

  defp update_link(socket, id, field, value) do
    link = Fresks.get_link!(id)
    {:ok, _} = link |> Link.changeset(%{field => nilify(value)}) |> Repo.update()
    socket |> reload() |> select_link(id)
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
      cards: reading_order(cards),
      sections: quadrant_order(sections),
      links: links,
      ann_by_id: ann_by_id
    )
  end

  # Sections are large/overlapping/nested, so row-banding collapses them. Order
  # them by quadrant instead — top-left, top-right, bottom-left, bottom-right
  # (by each box's center), then top-to-bottom / left-to-right within a quadrant.
  defp quadrant_order(anns) do
    Enum.sort_by(anns, fn a ->
      cx = (a.x1 + a.x2) / 2
      cy = (a.y1 + a.y2) / 2
      quad = if(cy < 0.5, do: 0, else: 2) + if(cx < 0.5, do: 0, else: 1)
      {quad, atop(a), aleft(a)}
    end)
  end

  # Reading order for the sidebar lists: group into rows top-to-bottom, then
  # left-to-right within each row (an item joins the current row while its
  # vertical center still falls inside that row's band).
  defp reading_order(anns) do
    anns
    |> Enum.sort_by(&atop/1)
    |> Enum.reduce([], fn a, rows ->
      case rows do
        [row | rest] ->
          row_bottom = row |> Enum.map(&abottom/1) |> Enum.max()
          if acenter_y(a) < row_bottom, do: [[a | row] | rest], else: [[a] | rows]

        [] ->
          [[a]]
      end
    end)
    |> Enum.reverse()
    |> Enum.flat_map(&Enum.sort_by(&1, fn a -> aleft(a) end))
  end

  defp atop(a), do: min(a.y1, a.y2)
  defp abottom(a), do: max(a.y1, a.y2)
  defp aleft(a), do: min(a.x1, a.x2)
  defp acenter_y(a), do: (a.y1 + a.y2) / 2

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
          <button
            :if={@fresk.status == "validated"}
            class="btn btn-ghost btn-sm"
            phx-click="invalidate-fresk"
          >
            <.icon name="hero-x-circle" class="size-4" /> Invalidate
          </button>
        </div>
      </div>

      <.progress_panel :if={@progress} progress={@progress} />

      <div class="flex gap-4 h-[calc(100vh-13rem)]">
        <div class="flex flex-1 flex-col gap-2 min-w-0">
          <div class="flex flex-wrap items-center gap-2 rounded-lg border border-base-300 bg-base-100 p-2">
            <div class="join">
              <.mode_button mode={@mode} value="pan" icon="hero-hand-raised" label="Pan" />
              <.mode_button mode={@mode} value="select" icon="hero-cursor-arrow-rays" label="Select" />
              <.mode_button mode={@mode} value="card" icon="hero-square-2-stack" label="Card" />
              <.mode_button mode={@mode} value="section" icon="hero-rectangle-group" label="Section" />
              <.mode_button mode={@mode} value="link" icon="hero-arrow-long-right" label="Link" />
            </div>

            <div class="mx-1 h-6 w-px bg-base-300"></div>

            <span class="text-xs font-medium text-base-content/50">Show</span>
            <div class="join">
              <.layer_button layer="cards" active={@layers.cards} label="Cards" />
              <.layer_button layer="sections" active={@layers.sections} label="Sections" />
              <.layer_button layer="arrows" active={@layers.arrows} label="Arrows" />
            </div>

            <div :if={@mode == "link"} class="mx-1 h-6 w-px bg-base-300"></div>
            <div :if={@mode == "link"} class="flex items-center gap-2">
              <span class="text-xs font-medium text-base-content/50">Arrow ends on</span>
              <.endpoint_select which="from" label="From" type={@link_from} />
              <.endpoint_select which="to" label="To" type={@link_to} />
            </div>

            <span :if={@mode == "link"} class="ml-auto text-xs text-base-content/50">
              click the start box, then the end box (or drag between them) · Esc cancels
            </span>
            <span :if={@mode != "link"} class="ml-auto text-xs text-base-content/50">
              scroll to zoom · Pan tool to move · Del to remove
            </span>
          </div>

          <div
            id="fresk-canvas"
            phx-hook="FreskCanvas"
            phx-update="ignore"
            class="relative flex-1 overflow-hidden rounded-lg border border-base-300 bg-base-200"
          >
            <canvas class="absolute inset-0 h-full w-full"></canvas>
          </div>
        </div>

        <aside class="flex w-80 flex-shrink-0 flex-col gap-3 overflow-hidden">
          <.inspector :if={@selected} selected={@selected} form={@annotation_form} />
          <.link_inspector
            :if={@selected_link}
            link={@selected_link}
            source_label={title_of(@ann_by_id[@selected_link.source_annotation_id])}
            target_label={title_of(@ann_by_id[@selected_link.target_annotation_id])}
          />

          <div class="join w-full">
            <.tab_button tab={@tab} value="cards" label="Cards" count={length(@cards)} />
            <.tab_button tab={@tab} value="sections" label="Sections" count={length(@sections)} />
            <.tab_button tab={@tab} value="arrows" label="Arrows" count={length(@links)} />
          </div>

          <div class="flex-1 overflow-y-auto rounded-lg border border-base-300 bg-base-100 p-1">
            <div :if={@tab == "cards"} class="flex flex-col">
              <p class="px-1.5 pb-1 text-xs text-base-content/50">{validated_line(@cards)}</p>
              <div
                :for={c <- @cards}
                class={[
                  "flex items-center gap-1 rounded p-1.5 text-sm hover:bg-base-200",
                  @selected && @selected.id == c.id && "bg-base-200 ring-1 ring-primary"
                ]}
              >
                <button
                  class="flex min-w-0 flex-1 items-center gap-2 text-left"
                  phx-click="select-annotation"
                  phx-value-id={c.id}
                >
                  <span
                    class="size-3 flex-shrink-0 rounded-sm border border-base-300"
                    style={"background:#{c.color}"}
                  >
                  </span>
                  <span class="truncate">{c.title || "Untitled"}</span>
                  <.icon
                    :if={low_conf?(c)}
                    name="hero-exclamation-triangle"
                    class="size-3.5 flex-shrink-0 text-warning"
                  />
                </button>
                <.validate_toggle item={c} />
              </div>
              <p :if={@cards == []} class="p-1.5 text-xs text-base-content/50">None detected.</p>
            </div>

            <div :if={@tab == "sections"} class="flex flex-col">
              <p class="px-1.5 pb-1 text-xs text-base-content/50">{validated_line(@sections)}</p>
              <div
                :for={s <- @sections}
                class={[
                  "flex items-center gap-1 rounded p-1.5 text-sm hover:bg-base-200",
                  @selected && @selected.id == s.id && "bg-base-200 ring-1 ring-primary"
                ]}
              >
                <button
                  class="flex min-w-0 flex-1 items-center gap-2 text-left"
                  phx-click="select-annotation"
                  phx-value-id={s.id}
                >
                  <.icon
                    name="hero-rectangle-group"
                    class="size-4 flex-shrink-0 text-base-content/40"
                  />
                  <span class="truncate">{s.title || "Untitled section"}</span>
                </button>
                <.validate_toggle item={s} />
              </div>
              <p :if={@sections == []} class="p-1.5 text-xs text-base-content/50">None detected.</p>
            </div>

            <div :if={@tab == "arrows"} class="flex flex-col">
              <div
                :for={l <- @links}
                class={[
                  "flex items-center gap-2 rounded p-1.5 text-sm",
                  @selected_link && @selected_link.id == l.id && "bg-base-200 ring-1 ring-primary"
                ]}
              >
                <button
                  class="flex min-w-0 flex-1 items-center gap-2 text-left"
                  phx-click="select-link"
                  phx-value-id={l.id}
                >
                  <.link_swatch color={link_color(l)} dashed={dashed?(l)} />
                  <span class="truncate text-xs">{link_label(@ann_by_id, l)}</span>
                </button>
                <button
                  class="btn btn-ghost btn-xs btn-circle text-error"
                  phx-click="link:delete"
                  phx-value-id={l.id}
                >
                  <.icon name="hero-trash" class="size-3.5" />
                </button>
              </div>
              <p :if={@links == []} class="p-1.5 text-xs text-base-content/50">
                No arrows yet — draw them in Link mode.
              </p>
            </div>
          </div>
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

  attr :tab, :string, required: true
  attr :value, :string, required: true
  attr :label, :string, required: true
  attr :count, :integer, required: true

  defp tab_button(assigns) do
    ~H"""
    <button
      type="button"
      class={["btn btn-sm join-item flex-1", @tab == @value && "btn-primary"]}
      phx-click="set-tab"
      phx-value-tab={@value}
    >
      {@label} <span class="ml-1 opacity-60">{@count}</span>
    </button>
    """
  end

  attr :layer, :string, required: true
  attr :active, :boolean, required: true
  attr :label, :string, required: true

  defp layer_button(assigns) do
    ~H"""
    <button
      class={["btn join-item btn-sm gap-1", @active && "btn-active"]}
      phx-click="toggle-layer"
      phx-value-layer={@layer}
      aria-pressed={to_string(@active)}
    >
      <.icon name={if @active, do: "hero-eye", else: "hero-eye-slash"} class="size-4" />
      <span class={[not @active && "text-base-content/40"]}>{@label}</span>
    </button>
    """
  end

  attr :item, :map, required: true

  defp validate_toggle(assigns) do
    ~H"""
    <button
      class={[
        "btn btn-ghost btn-xs btn-circle flex-shrink-0",
        if(@item.status == "validated", do: "text-success", else: "text-base-content/25")
      ]}
      phx-click="annotation:validate"
      phx-value-id={@item.id}
      title={if @item.status == "validated", do: "Validated — click to undo", else: "Mark validated"}
    >
      <.icon name="hero-check-circle-solid" class="size-4" />
    </button>
    """
  end

  attr :which, :string, required: true
  attr :label, :string, required: true
  attr :type, :string, required: true

  defp endpoint_select(assigns) do
    ~H"""
    <div class="flex items-center gap-1">
      <span class="text-xs text-base-content/60">{@label}</span>
      <div class="join">
        <button
          class={["btn btn-xs join-item", @type == "card" && "btn-primary"]}
          phx-click="set-link-endpoint"
          phx-value-which={@which}
          phx-value-type="card"
        >
          Card
        </button>
        <button
          class={["btn btn-xs join-item", @type == "section" && "btn-primary"]}
          phx-click="set-link-endpoint"
          phx-value-which={@which}
          phx-value-type="section"
        >
          Section
        </button>
      </div>
    </div>
    """
  end

  attr :selected, :map, required: true
  attr :form, :any, required: true

  defp inspector(assigns) do
    ~H"""
    <div class="rounded-lg border border-primary/40 bg-base-100 p-3">
      <div class="mb-2 flex items-center justify-between">
        <h3 class="text-sm font-semibold">Selected {@selected.type}</h3>
        <div class="flex items-center gap-1">
          <button
            class={[
              "btn btn-xs",
              if(@selected.status == "validated", do: "btn-success", else: "btn-outline")
            ]}
            phx-click="annotation:validate"
            phx-value-id={@selected.id}
          >
            <.icon name="hero-check-circle" class="size-4" />
            {if @selected.status == "validated", do: "Validated", else: "Validate"}
          </button>
          <button
            class="btn btn-ghost btn-xs text-error"
            phx-click="annotation:delete"
            phx-value-id={@selected.id}
          >
            <.icon name="hero-trash" class="size-4" />
          </button>
        </div>
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

  attr :link, :map, required: true
  attr :source_label, :string, required: true
  attr :target_label, :string, required: true

  defp link_inspector(assigns) do
    ~H"""
    <div class="rounded-lg border border-primary/40 bg-base-100 p-3">
      <div class="mb-2 flex items-center justify-between">
        <h3 class="text-sm font-semibold">Selected arrow</h3>
        <button
          class="btn btn-ghost btn-xs text-error"
          phx-click="link:delete"
          phx-value-id={@link.id}
        >
          <.icon name="hero-trash" class="size-4" /> Delete
        </button>
      </div>

      <div class="mb-3 flex items-center gap-2 text-sm">
        <span class="min-w-0 truncate font-medium">{@source_label}</span>
        <.icon name="hero-arrow-long-right" class="size-4 flex-shrink-0 text-base-content/40" />
        <span class="min-w-0 truncate font-medium">{@target_label}</span>
      </div>

      <label class="mb-1 block text-xs font-medium text-base-content/60">Line style</label>
      <div class="join mb-3">
        <button
          class={["btn btn-sm join-item", not dashed?(@link) && "btn-primary"]}
          phx-click="link:update"
          phx-value-id={@link.id}
          phx-value-field="line_style"
          phx-value-value="solid"
        >
          Solid
        </button>
        <button
          class={["btn btn-sm join-item", dashed?(@link) && "btn-primary"]}
          phx-click="link:update"
          phx-value-id={@link.id}
          phx-value-field="line_style"
          phx-value-value="dashed"
        >
          Dashed
        </button>
      </div>

      <label class="mb-1 block text-xs font-medium text-base-content/60">Color</label>
      <div class="join">
        <button
          type="button"
          class={["btn btn-sm join-item gap-1", link_color(@link) == "#16a34a" && "btn-primary"]}
          phx-click="link:update"
          phx-value-id={@link.id}
          phx-value-field="color"
          phx-value-value="#16a34a"
        >
          <span class="size-3 rounded-full" style="background:#16a34a"></span> Green
        </button>
        <button
          type="button"
          class={["btn btn-sm join-item gap-1", link_color(@link) == "#dc2626" && "btn-primary"]}
          phx-click="link:update"
          phx-value-id={@link.id}
          phx-value-field="color"
          phx-value-value="#dc2626"
        >
          <span class="size-3 rounded-full" style="background:#dc2626"></span> Red
        </button>
      </div>

      <p :if={@link.confidence} class="mt-3 text-xs text-base-content/50">
        detection confidence {round(@link.confidence * 100)}% · {@link.origin}
      </p>
    </div>
    """
  end

  attr :color, :string, required: true
  attr :dashed, :boolean, required: true

  defp link_swatch(assigns) do
    ~H"""
    <span class="flex h-3 w-6 flex-shrink-0 items-center">
      <span
        class="w-full"
        style={"border-top:2px #{if @dashed, do: "dashed", else: "solid"} #{@color}"}
      >
      </span>
    </span>
    """
  end

  defp low_conf?(%{confidence: c}) when is_float(c), do: c < 0.5
  defp low_conf?(_), do: false

  defp validated_line(items) do
    validated = Enum.count(items, &(&1.status == "validated"))
    "#{validated} of #{length(items)} validated"
  end

  defp link_label(ann_by_id, link) do
    src = ann_by_id[link.source_annotation_id]
    tgt = ann_by_id[link.target_annotation_id]
    "#{title_of(src)} → #{title_of(tgt)}"
  end

  defp title_of(nil), do: "?"
  defp title_of(%{title: nil, type: type}), do: "(#{type})"
  defp title_of(%{title: title}), do: title

  defp dashed?(%{line_style: "dashed"}), do: true
  defp dashed?(_), do: false

  defp link_color(%{color: c}) when is_binary(c) and c != "", do: c
  defp link_color(_), do: "#111827"
end
