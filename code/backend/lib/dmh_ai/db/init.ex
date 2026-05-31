# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.DB.Init do
  @moduledoc """
  Boot-time DB initialiser. Issues the schema (`Tables.create_all/0`)
  then the bootstrap and catalog seeders. Lives as a thin shell over
  sibling modules under `__MODULE__.{Tables, PoolSeed,
  OAuthCatalogSeed, BootstrapSeed}`.

  This module describes the schema as a fresh install only. Schema
  changes between releases are applied as one-off operator-run DB
  scripts; never as auto-running migrations on boot.
  """

  @db_dir "/data/db"

  def run do
    File.mkdir_p(@db_dir)
    File.mkdir_p(DmhAi.Constants.assets_dir())

    __MODULE__.Tables.create_all()
    __MODULE__.BootstrapSeed.seed_all()
    __MODULE__.PoolSeed.seed_all()
    __MODULE__.OAuthCatalogSeed.seed_all()
    :ok
  end
end
