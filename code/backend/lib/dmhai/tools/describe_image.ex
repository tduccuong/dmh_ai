# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.DescribeImage do
  @behaviour Dmhai.Tools.Behaviour

  alias Dmhai.Agent.{LLM, AgentSettings}
  require Logger

  @sandbox_root    "/tmp/dmhai-sandbox"
  @assets_root     "/data/user_assets"
  @max_dim         1024
  # Hard limit on raw file bytes if resize fails — refuse rather than send huge image.
  @max_raw_bytes   3_000_000

  @impl true
  def name, do: "describe_image"

  @impl true
  def description,
    do: "Describe the visual content of an image file. Returns a detailed structured description " <>
        "covering subjects, layout, text, actions, and mood."

  @impl true
  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          path: %{
            type: "string",
            description: "Path to the image file (.jpg, .png, .webp, .gif, .bmp, etc.). " <>
                         "Resolved within your sandbox or uploaded assets."
          }
        },
        required: ["path"]
      }
    }
  end

  @impl true
  def execute(%{"path" => path}, context) do
    user_id  = get_in(context, [:user, :id]) || "anon"
    resolved = resolve_path(path, user_id)

    with :ok        <- check_access(resolved, user_id),
         {:ok, b64} <- scale_and_encode(resolved) do
      messages = [%{role: "user", content: prompt(), images: [b64]}]

      case LLM.call(AgentSettings.image_describer_model(), messages) do
        {:ok, desc} when is_binary(desc) and desc != "" ->
          {:ok, desc}

        other ->
          Logger.warning("[DescribeImage] LLM call failed: #{inspect(other)}")
          {:error, "Image description failed"}
      end
    end
  end

  def execute(_, _), do: {:error, "Missing required argument: path"}

  # ── private ────────────────────────────────────────────────────────────────

  defp resolve_path(path, user_id) do
    sandbox = Path.expand(Path.join(@sandbox_root, to_string(user_id)))
    if String.starts_with?(path, "/"),
      do:   Path.expand(path),
      else: Path.expand(Path.join(sandbox, path))
  end

  defp check_access(resolved, user_id) do
    sandbox = Path.expand(Path.join(@sandbox_root, to_string(user_id)))
    assets  = Path.expand(Path.join(@assets_root,  to_string(user_id)))

    cond do
      not (String.starts_with?(resolved, sandbox) or String.starts_with?(resolved, assets)) ->
        {:error, "Access denied: path is outside allowed directories"}
      not File.exists?(resolved) ->
        {:error, "File not found: #{resolved}"}
      true ->
        :ok
    end
  end

  # Scale to max @max_dim on the longest side using ImageMagick (magick command).
  # If resize fails and the raw file exceeds @max_raw_bytes, returns an error
  # rather than forwarding an oversized payload to the LLM.
  defp scale_and_encode(path) do
    tmp = "/tmp/dmhai_img_#{System.unique_integer([:positive])}.jpg"

    try do
      {_, code} = System.cmd(
        "magick",
        [path, "-resize", "#{@max_dim}x#{@max_dim}>", "-quality", "85", tmp],
        stderr_to_stdout: true
      )

      if code == 0 and File.exists?(tmp) do
        case File.read(tmp) do
          {:ok, data} -> {:ok, Base.encode64(data)}
          {:error, r} -> {:error, "Cannot read resized image: #{r}"}
        end
      else
        # Resize failed — guard against oversized raw payloads.
        case File.stat(path) do
          {:ok, %{size: size}} when size > @max_raw_bytes ->
            {:error, "Image too large (#{size} bytes) and resize failed — install ImageMagick to enable automatic resizing"}

          _ ->
            case File.read(path) do
              {:ok, data} -> {:ok, Base.encode64(data)}
              {:error, r} -> {:error, "Cannot read image: #{r}"}
            end
        end
      end
    rescue
      _ ->
        case File.stat(path) do
          {:ok, %{size: size}} when size > @max_raw_bytes ->
            {:error, "Image too large (#{size} bytes) and ImageMagick is not available"}

          _ ->
            case File.read(path) do
              {:ok, data} -> {:ok, Base.encode64(data)}
              {:error, r} -> {:error, "Cannot read image: #{r}"}
            end
        end
    after
      File.rm(tmp)
    end
  end

  defp prompt do
    "Describe this image using the following structure:\n\n" <>
    "1. COUNTING RULE: For every countable category — people, animals, objects — state the exact number. " <>
        "Never write \"several\", \"some\", \"a few\", or \"many\". Always write \"1 cat\", \"3 fish\", etc.\n\n" <>
    "2. SUBJECTS: For every individual person, animal, and notable object — give each one its own numbered entry. " <>
        "Each entry must include: species/type, color(s), size, texture, position in the scene, and distinguishing features.\n\n" <>
    "3. LAYOUT: Describe spatial positions — foreground, center, background, left, right.\n\n" <>
    "4. SETTING: Location, environment, surface the objects rest on.\n\n" <>
    "5. LIGHTING: Light source direction, brightness, shadow presence.\n\n" <>
    "6. TEXT & SYMBOLS: Any visible text, numbers, logos, timestamps — quote exactly.\n\n" <>
    "7. ACTIONS & MOTION: What is happening, any movement or poses.\n\n" <>
    "8. MOOD: Overall atmosphere and tone.\n\n" <>
    "Be precise and exhaustive. A person who has never seen this image must be able to reconstruct it from your description alone."
  end
end
