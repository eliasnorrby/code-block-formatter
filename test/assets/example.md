# Example document

This is an example document with some code blocks.

Here's some badly formatted `yaml`. It should be formatted.

```yaml
steps:
- prettier
- will
- indent
- these items
```

Here's some erronous `yaml`. It should be marked with an error:

```yaml
steps:
- name: install dependencies
   run: npm install
```

Here's some properly formatted `yaml`. It should not be touched.

```yaml
tags:
  - a
  - list
  - of
  - tags
```

Here's some badly formatted `javascript`. It should be formatted.
```javascript
const a = ["mixing", 'quotes', "and", 'stuff' ];
```

Here's a list with some indented code blocks in it:

1. First, here's some properly formatted `yaml`:
   ```yaml
   this:
     is: a block
     with: a proper
     map:
       - in
       - it
   ```
2. Next up is some badly formatted `javascript`:
   ```javascript
   console
    .log(
    "why so many line breaks"
    )
   ```
