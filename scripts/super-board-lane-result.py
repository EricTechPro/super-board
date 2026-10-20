"""The shared one-shot lane result contract. No lifecycle state lives here."""
counts = {key: {'type': 'integer'} for key in ['fixed', 'notFixed', 'noLongerApplies']}
properties = {
    'status': {'type': 'string', 'enum': ['advanced', 'bounced', 'blocked', 'human-gate', 'failed', 'halted']},
    'column': {'type': 'string'}, 'detail': {'type': 'string'},
    'prUrl': {'type': ['string', 'null']}, 'branch': {'type': ['string', 'null']},
    'priorFindings': {'anyOf': [{'type': 'null'}, {'type': 'object', 'properties': counts,
                      'required': list(counts), 'additionalProperties': False}]},
}
schema = {'type': 'object', 'properties': properties, 'required': list(properties), 'additionalProperties': False}
JSON_TYPES = {'object': dict, 'array': list, 'string': str, 'null': type(None)}
def conforms(value, rule):
    # The subset of JSON Schema the lane schema uses: type, enum, anyOf, properties/required/additionalProperties.
    if 'anyOf' in rule:
        return any(conforms(value, option) for option in rule['anyOf'])
    kinds = rule['type'] if isinstance(rule['type'], list) else [rule['type']]
    if not any(type(value) is int if kind == 'integer' else isinstance(value, JSON_TYPES[kind]) for kind in kinds):
        return False
    if 'enum' in rule and value not in rule['enum']:
        return False
    if isinstance(value, dict):
        if set(value) - set(rule['properties']) or not set(rule['required']) <= set(value):
            return False
        return all(conforms(value[key], rule['properties'][key]) for key in value)
    return True
