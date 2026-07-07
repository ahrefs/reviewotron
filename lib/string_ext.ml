let contains_sub ~sub value = CCString.find ~sub value >= 0

let lower_contains ~sub value = contains_sub ~sub (String.lowercase_ascii value)
