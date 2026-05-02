# Tests for AgentSettings.migrate_legacy_model_keys/0 — collapses the
# pre-tier model setting keys (compactorModel, summarizerModel,
# webSearchModel, oracleModel-old, imageDescriberModel,
# videoDescriberModel, profileExtractorModel) into the new Swift /
# Oracle / Vision tiers. Idempotent on re-run.

defmodule Itgr.AgentSettingsMigration do
  use ExUnit.Case, async: false

  alias DmhAi.Agent.AgentSettings
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  setup do
    # Snapshot the existing admin_cloud_settings row (if any) and
    # restore on exit so this test doesn't pollute other suites.
    snapshot =
      case query!(Repo, "SELECT value FROM settings WHERE key=?", ["admin_cloud_settings"]) do
        %{rows: [[v]]} -> v
        _              -> nil
      end

    on_exit(fn ->
      if snapshot do
        query!(Repo,
               "INSERT INTO settings (key, value) VALUES (?, ?) " <>
                 "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
               ["admin_cloud_settings", snapshot])
      else
        query!(Repo, "DELETE FROM settings WHERE key=?", ["admin_cloud_settings"])
      end
    end)

    :ok
  end

  defp put_settings(map) do
    query!(Repo,
           "INSERT INTO settings (key, value) VALUES (?, ?) " <>
             "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
           ["admin_cloud_settings", Jason.encode!(map)])
  end

  defp current_settings do
    case query!(Repo, "SELECT value FROM settings WHERE key=?", ["admin_cloud_settings"]) do
      %{rows: [[v]]} -> Jason.decode!(v)
      _              -> %{}
    end
  end

  describe "migrate_legacy_model_keys/0" do
    test "old oracleModel value carries forward to swiftModel (Class A semantic preserved)" do
      put_settings(%{"oracleModel" => "miner::ministral-3:14b"})

      AgentSettings.migrate_legacy_model_keys()
      after_migrate = current_settings()

      assert Map.get(after_migrate, "swiftModel") == "miner::ministral-3:14b"
      refute Map.has_key?(after_migrate, "oracleModel")
    end

    test "compactor / summarizer / profileExtractor collapse into oracleModel (new meaning)" do
      put_settings(%{"compactorModel" => "miner::gemma4:31b"})

      AgentSettings.migrate_legacy_model_keys()
      after_migrate = current_settings()

      assert Map.get(after_migrate, "oracleModel") == "miner::gemma4:31b"
      refute Map.has_key?(after_migrate, "compactorModel")
    end

    test "imageDescriber / videoDescriber collapse into visionModel" do
      put_settings(%{
        "imageDescriberModel" => "miner::vision-a",
        "videoDescriberModel" => "miner::vision-b"
      })

      AgentSettings.migrate_legacy_model_keys()
      after_migrate = current_settings()

      # First-write-wins: imageDescriber lands first (per @legacy_model_key_map order).
      assert Map.get(after_migrate, "visionModel") == "miner::vision-a"
      refute Map.has_key?(after_migrate, "imageDescriberModel")
      refute Map.has_key?(after_migrate, "videoDescriberModel")
    end

    test "first-write-wins for swift tier — old oracleModel beats webSearchModel" do
      put_settings(%{
        "oracleModel"    => "miner::pivot-pick",
        "webSearchModel" => "miner::websearch-pick"
      })

      AgentSettings.migrate_legacy_model_keys()
      after_migrate = current_settings()

      # @legacy_model_key_map lists oracleModel before webSearchModel.
      assert Map.get(after_migrate, "swiftModel") == "miner::pivot-pick"
      refute Map.has_key?(after_migrate, "oracleModel")
      refute Map.has_key?(after_migrate, "webSearchModel")
    end

    test "operator-set tier value is NOT clobbered by legacy carry-over" do
      put_settings(%{
        "swiftModel"     => "miner::operator-pick",
        "oracleModel"    => "miner::legacy-old-fast",
        "webSearchModel" => "miner::legacy-old-search"
      })

      AgentSettings.migrate_legacy_model_keys()
      after_migrate = current_settings()

      # operator's swiftModel was already set — preserved.
      assert Map.get(after_migrate, "swiftModel") == "miner::operator-pick"
      refute Map.has_key?(after_migrate, "oracleModel")
      refute Map.has_key?(after_migrate, "webSearchModel")
    end

    test "fully-migrated DB is a no-op on re-run (idempotent)" do
      put_settings(%{
        "swiftModel"  => "miner::a",
        "oracleModel" => "miner::b",
        "visionModel" => "miner::c"
      })

      AgentSettings.migrate_legacy_model_keys()
      first_pass = current_settings()

      AgentSettings.migrate_legacy_model_keys()
      second_pass = current_settings()

      assert first_pass == second_pass
    end

    test "fresh install with no settings row is a no-op" do
      query!(Repo, "DELETE FROM settings WHERE key=?", ["admin_cloud_settings"])

      assert :ok = AgentSettings.migrate_legacy_model_keys()

      # Either the row is still absent, or migrate wrote an empty
      # placeholder — both are acceptable; no legacy keys should exist.
      after_migrate = current_settings()

      for legacy <- ~w(compactorModel summarizerModel webSearchModel imageDescriberModel
                       videoDescriberModel profileExtractorModel) do
        refute Map.has_key?(after_migrate, legacy)
      end
    end

    test "preserves unrelated settings (compactTurns, modelLabels, etc.)" do
      put_settings(%{
        "compactTurns"   => 90,
        "modelLabels"    => %{"foo" => "bar"},
        "compactorModel" => "miner::heavy"
      })

      AgentSettings.migrate_legacy_model_keys()
      after_migrate = current_settings()

      assert Map.get(after_migrate, "compactTurns") == 90
      assert Map.get(after_migrate, "modelLabels") == %{"foo" => "bar"}
      assert Map.get(after_migrate, "oracleModel") == "miner::heavy"
    end
  end
end
