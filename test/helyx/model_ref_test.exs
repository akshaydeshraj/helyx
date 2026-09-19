defmodule Helyx.ModelRefTest do
  use ExUnit.Case, async: true

  alias Helyx.ModelRef

  test "a ref splits at the first slash and joins back" do
    assert {:ok, %ModelRef{provider: "a", model: "b/c"} = ref} = ModelRef.parse("a/b/c")
    assert ModelRef.to_string(ref) == "a/b/c"
  end

  test "both parts must be present" do
    for bad <- ["", "a", "a/", "/b", "/"] do
      assert {:error, {:invalid_model_ref, ^bad}} = ModelRef.parse(bad)
    end
  end

  test "the limit is 256 bytes: at it, one under, one over, and multibyte" do
    ref = fn bytes -> "p/" <> String.duplicate("m", bytes - 2) end

    assert {:ok, _} = ModelRef.parse(ref.(255))
    assert {:ok, _} = ModelRef.parse(ref.(256))
    assert {:error, {:invalid_model_ref, _}} = ModelRef.parse(ref.(257))

    # 127 two-byte characters: 256 bytes with the prefix, 258 with one more.
    assert {:ok, _} = ModelRef.parse("p/" <> String.duplicate("é", 127))
    assert {:error, {:invalid_model_ref, _}} = ModelRef.parse("p/" <> String.duplicate("é", 128))
  end

  test "characters that show as nothing but are outside category C are accepted" do
    # The stated limit of the rule: two refs that look the same can differ.
    for shown_as_nothing <- ["\u3164", "\u2800", "\uFE0F", "\u034F"] do
      assert {:ok, %ModelRef{model: model}} = ModelRef.parse("p/a" <> shown_as_nothing <> "b")
      assert model == "a" <> shown_as_nothing <> "b"
    end
  end

  test "invalid UTF-8, whitespace, and category C characters are rejected" do
    for bad <- [<<"p/", 255>>, "p/a b", "p/a\n", "p/\e]0;x", "p/a\u200Bb", " p/a", "p/a\u00A0b"] do
      assert {:error, {:invalid_model_ref, ^bad}} = ModelRef.parse(bad)
    end
  end
end
