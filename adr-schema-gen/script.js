// Reference to the JSON input textarea
const jsonInputElement = document.getElementById('json-input');

// Set "Include 'StatusCode' field" to unchecked by default
document.getElementById('include-statuscode').checked = false;

// Event listener for Generate Schema button
document.getElementById('generate-button').addEventListener('click', () => {
  const jsonInput = document.getElementById('json-input').value;
  const outputElement = document.getElementById('schema-output');
  const errorMessage = document.getElementById('error-message');
  const forceNullable = document.getElementById('force-nullable').checked;
  const includeStatusCode = document.getElementById('include-statuscode').checked;
  const schemaType = document.querySelector('input[name="schemaType"]:checked').value;

  try {
    // Validate JSON input
    const jsonObject = jsonlint.parse(jsonInput);

    // Clear previous error message
    errorMessage.textContent = '';

    let schema;
    if (schemaType === 'delta') {
      // Generate Delta schema
      schema = generateDeltaSchema(jsonObject, forceNullable, includeStatusCode);
    } else if (schemaType === 'json') {
      // Generate JSON schema
      schema = generateJsonSchema(jsonObject, forceNullable);
    }

    const schemaText = JSON.stringify(schema, null, 2);
    outputElement.textContent = schemaText;
    Prism.highlightElement(outputElement);
  } catch (error) {
    // Display error message
    errorMessage.textContent = 'Error: ' + error.message;
  }
});

// Event listener for Download Schema button
document.getElementById('download-button').addEventListener('click', () => {
  const schemaOutput = document.getElementById('schema-output').textContent;
  if (!schemaOutput) {
    alert('No schema to download. Please generate the schema first.');
    return;
  }
  const blob = new Blob([schemaOutput], { type: 'application/json' });
  const url = URL.createObjectURL(blob);

  const a = document.createElement('a');
  a.href = url;
  a.download = 'schema.json';
  a.click();
  URL.revokeObjectURL(url);
});

// Event listener for Copy button
document.getElementById('copy-button').addEventListener('click', () => {
  const schemaOutput = document.getElementById('schema-output').textContent;
  const copySuccess = document.getElementById('copy-success');

  if (!schemaOutput) {
    // Display an error message near the copy icon
    copySuccess.textContent = 'No schema to copy!';
    copySuccess.style.color = 'red';
    copySuccess.classList.add('show');
    setTimeout(() => {
      copySuccess.classList.remove('show');
    }, 2000); // Hide after 2 seconds
    return;
  }

  navigator.clipboard.writeText(schemaOutput).then(() => {
    // Display success message
    copySuccess.textContent = 'Schema copied!';
    copySuccess.style.color = '#28a745';
    copySuccess.classList.add('show');
    setTimeout(() => {
      copySuccess.classList.remove('show');
    }, 2000); // Hide after 2 seconds
  }, (err) => {
    // Display error message
    copySuccess.textContent = 'Failed to copy!';
    copySuccess.style.color = 'red';
    copySuccess.classList.add('show');
    setTimeout(() => {
      copySuccess.classList.remove('show');
    }, 2000); // Hide after 2 seconds
  });
});

// Show or hide schema details based on selected schema type
const schemaTypeRadios = document.querySelectorAll('input[name="schemaType"]');
const schemaDetailsSection = document.getElementById('schema-details');
const includeStatusCodeOption = document.getElementById('include-statuscode-option');

function updateOptionsVisibility() {
  if (document.getElementById('jsonSchema').checked) {
    schemaDetailsSection.style.display = 'block';
    includeStatusCodeOption.style.display = 'none';
  } else {
    schemaDetailsSection.style.display = 'none';
    includeStatusCodeOption.style.display = 'block';
  }
}

schemaTypeRadios.forEach(radio => {
  radio.addEventListener('change', updateOptionsVisibility);
});

// Initial visibility update
updateOptionsVisibility();

function generateDeltaSchema(jsonObj, forceNullable, includeStatusCode) {
  function getType(value) {
    if (value === null) {
      return 'null';
    } else if (Array.isArray(value)) {
      // Determine the element type of the array
      const elementTypes = new Set(value.map(getType));
      const elementType = elementTypes.size === 1 ? [...elementTypes][0] : 'string'; // Default to string if mixed types
      return {
        type: 'array',
        elementType: elementType,
        containsNull: value.includes(null)
      };
    } else if (typeof value === 'object') {
      // Treat all objects as structs unless explicitly identified as maps
      return 'struct';
    } else if (typeof value === 'number') {
      if (Number.isInteger(value)) {
        // Check the range of the integer
        if (value >= -2147483648 && value <= 2147483647) {
          return 'integer';
        } else {
          return 'long';
        }
      } else {
        // Use 'double' for all floating point numbers
        return 'double';
      }
    } else if (typeof value === 'boolean') {
      return 'boolean';
    } else if (typeof value === 'string') {
      if (isDate(value)) {
        return 'date';
      } else if (isTimestamp(value)) {
        return 'timestamp';
      } else if (isBinary(value)) {
        return 'binary';
      } else if (isDecimal(value)) {
        const { precision, scale } = getDecimalPrecisionScale(value);
        return {
          type: 'decimal',
          precision: precision,
          scale: scale
        };
      } else {
        return 'string';
      }
    } else {
      return 'string';
    }
  }

  function getNullable(value) {
    if (forceNullable) {
      return true;
    } else {
      return value === null;
    }
  }

  function statusCodeField() {
    return {
      name: 'StatusCode',
      type: {
        type: 'struct',
        fields: [
          {
            name: 'Code',
            type: 'integer',
            nullable: true,
            metadata: {}
          },
          {
            name: 'Symbol',
            type: 'string',
            nullable: true,
            metadata: {}
          }
        ]
      },
      nullable: true,
      metadata: {}
    };
  }

  // Helper functions
  function isDate(value) {
    // Simple regex to detect date strings (YYYY-MM-DD)
    return /^\d{4}-\d{2}-\d{2}$/.test(value);
  }

  function isTimestamp(value) {
    // Simple regex to detect timestamp strings (ISO 8601 format)
    return /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z?$/.test(value);
  }

  function isBinary(value) {
    // Simple check for base64 encoded strings (not comprehensive)
    try {
      return btoa(atob(value)) === value;
    } catch (err) {
      return false;
    }
  }

  function isDecimal(value) {
    // Check if string represents a decimal number
    return /^-?\d+\.\d+$/.test(value);
  }

  function getDecimalPrecisionScale(value) {
    // Calculate precision and scale for decimal values
    const [integerPart, fractionalPart] = value.replace('-', '').split('.');
    const precision = integerPart.length + (fractionalPart ? fractionalPart.length : 0);
    const scale = fractionalPart ? fractionalPart.length : 0;
    return { precision, scale };
  }

  function generateFields(obj) {
    const fields = [];

    for (const [key, value] of Object.entries(obj)) {
      const fieldType = getType(value);

      if (fieldType === 'struct') {
        // For nested objects
        const subFields = generateFields(value);

        // Include StatusCode field if it's not already present and option is enabled
        if (includeStatusCode && !value.hasOwnProperty('StatusCode')) {
          subFields.push(statusCodeField());
        }

        fields.push({
          name: key,
          type: {
            type: 'struct',
            fields: subFields
          },
          nullable: getNullable(value),
          metadata: {}
        });
      } else if (fieldType.type === 'array') {
        // For arrays
        fields.push({
          name: key,
          type: {
            type: 'array',
            elementType: fieldType.elementType,
            containsNull: fieldType.containsNull
          },
          nullable: getNullable(value),
          metadata: {}
        });
      } else if (fieldType.type === 'decimal') {
        // For decimal type
        fields.push({
          name: key,
          type: {
            type: 'decimal',
            precision: fieldType.precision,
            scale: fieldType.scale
          },
          nullable: getNullable(value),
          metadata: {}
        });
      } else {
        // For primitive types
        fields.push({
          name: key,
          type: fieldType,
          nullable: getNullable(value),
          metadata: {}
        });
      }
    }

    return fields;
  }

  const schema = {
    $schema: 'Delta/1.0',
    type: 'object',
    properties: {
      type: 'struct',
      fields: generateFields(jsonObj)
    }
  };

  return schema;
}

function generateJsonSchema(jsonObj, forceNullable) {
  const name = document.getElementById('schema-name').value || 'DefaultName';
  const description = document.getElementById('schema-description').value || 'A representation of an object';

  function getType(value) {
    if (value === null) {
      return ['null'];
    } else if (Array.isArray(value)) {
      return 'array';
    } else if (typeof value === 'object') {
      return 'object';
    } else if (typeof value === 'number') {
      return Number.isInteger(value) ? 'integer' : 'number';
    } else if (typeof value === 'boolean') {
      return 'boolean';
    } else if (typeof value === 'string') {
      return 'string';
    } else {
      return 'string';
    }
  }

  function generateSchema(obj) {
    if (obj === null) {
      return { type: 'null' };
    } else if (Array.isArray(obj)) {
      const items = obj.map(generateSchema);
      return {
        type: 'array',
        items: items.length === 1 ? items[0] : { anyOf: items }
      };
    } else if (typeof obj === 'object') {
      const properties = {};
      const required = [];
      for (const [key, value] of Object.entries(obj)) {
        properties[key] = generateSchema(value);
        if (!forceNullable && value !== null) {
          required.push(key);
        }
      }
      const schemaObj = {
        type: 'object',
        properties: properties
      };
      if (required.length > 0) {
        schemaObj.required = required;
      }
      return schemaObj;
    } else {
      return { type: getType(obj) };
    }
  }

  const schema = {
    $schema: 'http://json-schema.org/draft-07/schema#',
    name: name,
    description: description,
    ...generateSchema(jsonObj)
  };

  return schema;
}
