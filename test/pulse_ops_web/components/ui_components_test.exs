defmodule PulseOpsWeb.UIComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest
  import PulseOpsWeb.UIComponents

  describe "list_card/1" do
    test "gives every item its own row and keeps the row's layout" do
      assigns = %{names: ["CI pipeline", "Nightly backup"]}

      html =
        rendered_to_string(~H"""
        <.list_card id="tokens">
          <:item :for={name <- @names} class="flex justify-between">{name}</:item>
        </.list_card>
        """)

      assert html =~ ~s(id="tokens")
      assert length(Regex.scan(~r/<li\b/, html)) == 2
      assert html =~ "CI pipeline"
      assert html =~ "Nightly backup"
      # The shared padding and the item's own layout both reach the row.
      assert html =~ ~r/<li class="p-4 sm:p-5 flex justify-between"/
    end
  end

  describe "empty_state/1" do
    test "passes an id through so a page can point at it" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.empty_state id="nothing-here" title="Nothing here">
          <:subtitle>Add something.</:subtitle>
        </.empty_state>
        """)

      assert html =~ ~s(id="nothing-here")
      assert html =~ "Nothing here"
      assert html =~ "Add something."
    end
  end

  describe "confirmation_dialog/1" do
    test "is a labelled modal dialog carrying the consequence and both choices" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.confirmation_dialog id="delete-service" show title="Delete service" confirm_label="Delete">
          Its checks and incidents go with it.
        </.confirmation_dialog>
        """)

      assert html =~ ~s(role="dialog")
      assert html =~ ~s(aria-modal="true")
      assert html =~ ~s(aria-labelledby="delete-service-title")
      assert html =~ ~s(id="delete-service-title")
      assert html =~ ~s(aria-describedby="delete-service-desc")
      assert html =~ "Its checks and incidents go with it."
      assert html =~ "Cancel"
      assert html =~ ~r/btn-error[^>]*>\s*Delete/
      # Shown on mount, so it opens as soon as the page renders it.
      assert html =~ "phx-mounted"
    end

    test "stays closed until asked to show" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.modal id="later">
          <p>Not yet.</p>
        </.modal>
        """)

      assert html =~ ~s(class="relative z-50 hidden")
      refute html =~ "phx-mounted"
    end
  end

  describe "skeleton/1" do
    test "pulses in the requested shape" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.skeleton variant="circle" class="size-8" />
        """)

      assert html =~ "animate-pulse"
      assert html =~ "rounded-full"
      assert html =~ "size-8"
    end
  end

  describe "badge/1" do
    test "spells out the colour class of every variant so Tailwind generates it" do
      for variant <- ["filled", "outline", "ghost"],
          {color, class} <- [
            {"default", "text-base-content/80"},
            {"success", "text-success"},
            {"error", "text-error"}
          ] do
        assigns = %{variant: variant, color: color}

        html =
          rendered_to_string(~H"""
          <.badge variant={@variant} color={@color}>Up</.badge>
          """)

        assert html =~ class, "#{variant} #{color} badge is missing #{class}"
        refute html =~ "text-default"
      end
    end

    test "scales with its size" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.badge size="lg" color="error">P1</.badge>
        """)

      assert html =~ "text-base"
      assert html =~ "P1"
    end
  end

  describe "tabs/1" do
    test "marks the active tab and keeps slot bookkeeping out of the markup" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.tabs>
          <:tab active phx-click="set_tab" phx-value-tab="all">All</:tab>
          <:tab active={false} phx-click="set_tab" phx-value-tab="open">Open</:tab>
        </.tabs>
        """)

      assert html =~ ~s(role="tablist")
      assert html =~ ~s(aria-selected="true")
      assert html =~ ~s(aria-selected="false")
      assert html =~ ~s(phx-value-tab="open")
      refute html =~ "__slot__"
      refute html =~ ~r/\sactive[\s=>]/
    end
  end

  describe "pagination/1" do
    defp render_pagination(current, total) do
      assigns = %{current: current, total: total}

      rendered_to_string(~H"""
      <.pagination current={@current} total={@total} />
      """)
    end

    # What a reader sees between the arrows: page numbers and gaps, in order.
    defp pages(current, total) do
      ~r/aria-label="Page (\d+)"|(…)/u
      |> Regex.scan(render_pagination(current, total))
      |> Enum.map(fn
        [_match, page] -> page
        [_match, "", gap] -> gap
      end)
    end

    test "is not drawn for a single page" do
      refute render_pagination(1, 1) =~ "<nav"
    end

    test "lists every page when there are few" do
      assert pages(2, 5) == ["1", "2", "3", "4", "5"]
    end

    test "only puts a gap where pages were skipped" do
      assert pages(5, 10) == ["1", "…", "4", "5", "6", "…", "10"]
      assert pages(1, 10) == ["1", "2", "…", "10"]
      assert pages(3, 10) == ["1", "2", "3", "4", "…", "10"]
      assert pages(10, 10) == ["1", "…", "9", "10"]
    end

    test "names its controls and marks the current page" do
      html = render_pagination(1, 3)

      assert html =~ ~s(aria-label="Previous page")
      assert html =~ ~s(aria-label="Next page")
      assert html =~ ~r/aria-label="Page 1"[^>]*aria-current="page"/
      assert html =~ ~r/<button[^>]*disabled[^>]*aria-label="Previous page"/
    end
  end
end
