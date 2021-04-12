local utils = require("kong.tools.utils")


local CLUSTER_ID = utils.uuid()


return {
  postgres = {
    up = string.format([[
      DO $$
      BEGIN
        ALTER TABLE IF EXISTS ONLY "clustering_data_planes" ADD "cert_exp_date" TIMESTAMP WITH TIME ZONE;
      EXCEPTION WHEN DUPLICATE_COLUMN THEN
        -- Do nothing, accept existing state
      END;
      $$;
    ]], CLUSTER_ID),
  },
  cassandra = {
    up = string.format([[
      ALTER TABLE clustering_data_planes ADD cert_exp_date timestamp;
    ]], CLUSTER_ID),
  }
}
