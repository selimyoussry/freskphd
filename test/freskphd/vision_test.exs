defmodule Freskphd.VisionTest do
  use ExUnit.Case, async: true

  alias Freskphd.Vision

  @tiny Base.encode64(<<137, 80, 78, 71>>)

  describe "read_crops/2" do
    test "returns one text per crop, in order" do
      Req.Test.stub(Freskphd.VisionStub, fn conn ->
        Req.Test.json(conn, %{
          "choices" => [
            %{"message" => %{"content" => Jason.encode!(%{"texts" => ["ALPHA", "BETA"]})}}
          ]
        })
      end)

      assert {:ok, ["ALPHA", "BETA"]} = Vision.read_crops([@tiny, @tiny])
    end

    test "invokes the progress callback with cumulative counts" do
      Req.Test.stub(Freskphd.VisionStub, fn conn ->
        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"content" => Jason.encode!(%{"texts" => ["X"]})}}]
        })
      end)

      me = self()
      Vision.read_crops([@tiny], fn done, total -> send(me, {:progress, done, total}) end)
      assert_received {:progress, 1, 1}
    end

    test "empty input short-circuits" do
      assert {:ok, []} = Vision.read_crops([])
    end
  end

  describe "configuration" do
    test "returns :not_configured when no api key is set" do
      original = Application.get_env(:freskphd, :vision)
      Application.put_env(:freskphd, :vision, Keyword.put(original, :api_key, nil))
      on_exit(fn -> Application.put_env(:freskphd, :vision, original) end)

      refute Vision.configured?()
      assert {:error, :not_configured} = Vision.read_crops([@tiny])
    end
  end
end
