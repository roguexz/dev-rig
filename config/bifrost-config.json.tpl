{
  "$schema": "https://www.getbifrost.ai/schema",
  "encryption_key": "env.BIFROST_ENCRYPTION_KEY",

  "client": {
    "enforce_auth_on_inference": true,
    "mcp_disable_auto_tool_inject": true,
    "enable_logging": true
  },

  "config_store": {
    "enabled": true,
    "type": "sqlite",
    "config": {
      "path": "/data/bifrost.db"
    }
  },

  "logs_store": {
    "enabled": true,
    "type": "sqlite",
    "config": {
      "path": "/data/logs.db"
    }
  },

  "governance": {
    "auth_config": {
      "is_enabled": true,
      "admin_username": "env.BIFROST_ADMIN_USERNAME",
      "admin_password": "env.BIFROST_ADMIN_PASSWORD",
      "disable_auth_on_inference": false
    },

    "virtual_keys": [
      {
        "id": "vk-opencode",
        "name": "opencode",
        "value": "env.BIFROST_VK_OPENCODE",
        "is_active": true,
        "allow_all_providers": true
      }
    ]
  },

  "providers": {{PROVIDERS_SECTION}},

  "plugins": [
    {
      "enabled": true,
      "name": "telemetry"
    },
    {
      "enabled": true,
      "name": "logging"
    },
    {
      "enabled": true,
      "name": "governance",
      "config": {
        "is_vk_mandatory": true
      }
    }
  ]
}
