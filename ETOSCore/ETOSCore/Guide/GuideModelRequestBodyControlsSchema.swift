import Foundation

extension GuideModelRequestBodyControls {
    public static let toolDefinition = InternalToolDefinition(
        name: "propose_model_request_body_controls",
        description: NSLocalizedString("guide.controls.tool.description", value: "Propose creating, updating or explicitly deleting structured request controls on this model. Omit id to create; use an existing id to patch only supplied fields. Payloads are arbitrary JSON objects, not limited to reasoning. Supplied payload/options replace that field; omitted fields and hidden credentials are preserved. options is a complete list with stable option IDs. current_* changes the current selection, while default_* only changes defaults. Requires native user confirmation before saving. Read model-request-body first; inspect exact-version source if app behavior is unclear.", comment: "向导结构化控制工具说明"),
        parameters: GuideToolCatalog.objectSchema(properties: [
            "controls": .dictionary([
                "type": .string("array"),
                "items": GuideToolCatalog.objectSchema(properties: controlProperties)
            ]),
            "remove_control_ids": .dictionary([
                "type": .string("array"), "items": .dictionary(["type": .string("string")])
            ])
        ])
    )

    static let optionOnlyKeys: Set<String> = [
        "options", "default_option_id", "slider_enabled", "slider_granularity", "slider_start_color",
        "slider_end_color", "rainbow_at_maximum", "current_option_id", "current_slider_position"
    ]

    static let controlProperties: [String: JSONValue] = [
        "id": .dictionary(["type": .string("string")]),
        "title": .dictionary(["type": .string("string")]),
        "kind": .dictionary(["type": .string("string"), "enum": .array([.string("toggle"), .string("optionGroup")])]),
        "enabled": .dictionary(["type": .string("boolean")]),
        "default_active": .dictionary(["type": .string("boolean")]),
        "default_option_id": .dictionary(["type": .string("string")]),
        "slider_enabled": .dictionary(["type": .string("boolean")]),
        "slider_granularity": GuideRequestBodyControlSettingsSupport.optionalPositiveNumberSchema,
        "slider_start_color": GuideRequestBodyControlSettingsSupport.optionalColorSchema,
        "slider_end_color": GuideRequestBodyControlSettingsSupport.optionalColorSchema,
        "rainbow_at_maximum": .dictionary(["type": .string("boolean")]),
        "payload": GuideRequestBodyControlSettingsSupport.payloadSchema,
        "options": GuideRequestBodyControlSettingsSupport.optionsSchema,
        "current_active": .dictionary(["type": .string("boolean")]),
        "current_option_id": .dictionary(["type": .string("string")]),
        "current_slider_position": .dictionary(["type": .string("number"), "minimum": .int(0), "maximum": .int(1)])
    ]
}
