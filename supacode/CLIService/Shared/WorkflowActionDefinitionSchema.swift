nonisolated public enum WorkflowActionDefinitionSchema {
  public static let json = #"""
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "$id": "https://prowl.onev.cat/contracts/action/v1/action-definition.json",
      "title": "Prowl Script Action",
      "type": "object",
      "additionalProperties": false,
      "required": [
        "schema",
        "name",
        "input_schema",
        "output_schema",
        "backend"
      ],
      "properties": {
        "schema": {
          "const": "prowl.action/v1"
        },
        "name": {
          "type": "string",
          "minLength": 1
        },
        "input_schema": {
          "type": "object",
          "required": [
            "type"
          ],
          "properties": {
            "type": {
              "const": "object"
            }
          }
        },
        "output_schema": {
          "type": "object",
          "required": [
            "type"
          ],
          "properties": {
            "type": {
              "const": "object"
            }
          }
        },
        "timeout": {
          "type": "string",
          "pattern": "^[1-9][0-9]*s$"
        },
        "backend": {
          "type": "object",
          "additionalProperties": false,
          "required": [
            "type",
            "interpreter",
            "entrypoint"
          ],
          "properties": {
            "type": {
              "const": "script"
            },
            "interpreter": {
              "type": "string",
              "minLength": 1
            },
            "entrypoint": {
              "type": "string",
              "minLength": 1
            },
            "arguments": {
              "type": "array",
              "items": {
                "type": "string"
              }
            },
            "inherit_env": {
              "type": "array",
              "items": {
                "type": "string",
                "pattern": "^[A-Za-z_][A-Za-z0-9_]*$"
              }
            }
          }
        }
      }
    }
    """#
}
