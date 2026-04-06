# MCP (Model Context Protocol) Configuration

## Overview

MCP servers provide Claude with access to external tools and services through a standardized
protocol. This documentation covers the correct configuration process for Claude Desktop and
the repository's role in managing MCP configurations.

## Configuration Locations

### Claude Desktop Configuration

**Primary Config File**: `~/Library/Application Support/Claude/claude_desktop_config.json`

This is the actual configuration file that Claude Desktop reads. All MCP servers must be
configured here to work with Claude Desktop.

### Repository Source Configuration

**Source File**: `/.mcp.json` (in repository root)

This file serves as the reference for MCP server configurations and is merged into
Claude Desktop's configuration during deployment.

## Configuration Structure

### Claude Desktop Format

```json
{
  "mcpServers": {
    "server-name": {
      "command": "npx",
      "args": ["-y", "package-name"],
      "env": {
        "API_KEY": "${API_KEY}"
      }
    }
  }
}
```

### Repository Source Format

The `.mcp.json` in the repository uses the same structure as Claude Desktop's configuration,
containing only the `mcpServers` section that gets merged into the full config.

## Available MCP Servers

### 1. Filesystem

- **Purpose**: File system operations
- **Package**: `@modelcontextprotocol/server-filesystem`
- **Access**: Documents directory by default

### 2. GitHub

- **Purpose**: GitHub repository operations
- **Package**: `@modelcontextprotocol/server-github`
- **Environment**: Requires `GITHUB_TOKEN`

### 3. ShadCN UI

- **Purpose**: UI component library access
- **Package**: `shadcn-ui-mcp-server`
- **Usage**: UI/UX development

### 4. Context7

- **Purpose**: Documentation and API lookups
- **Package**: `@upstash/context7-mcp`
- **Environment**: Requires `CONTEXT7_API_KEY`

### 5. ElevenLabs

- **Purpose**: Text-to-speech and voice generation
- **Package**: `elevenlabs-streaming-mcp-server`
- **Environment**: Requires `ELEVENLABS_API_KEY`

### 6. Notion API

- **Purpose**: Notion workspace integration
- **Package**: `@notionhq/notion-mcp-server`
- **Environment**: Requires `NOTION_API_KEY`

## Deployment Process

The `/sync` command now properly handles MCP server configuration deployment:

```bash
# From claude-config repository
/sync

# Process:
# 1. Reads repository .mcp.json
# 2. Merges MCP servers into Claude Desktop config
# 3. Creates backup of existing Claude Desktop config
# 4. Updates ~/Library/Application Support/Claude/claude_desktop_config.json
# 5. Validates configuration syntax
```

### Deployment Steps

1. **Backup Creation**: Existing Claude Desktop config is backed up
2. **Configuration Merge**: Repository MCP servers are merged with existing config
3. **File Update**: Claude Desktop config file is updated with merged configuration
4. **Validation**: JSON syntax and structure are validated
5. **Restart Prompt**: User is reminded to restart Claude Desktop

## Adding New MCP Servers

1. Edit `.mcp.json` in the repository root:

   ```json
   {
     "mcpServers": {
       "your-server": {
         "command": "npx",
         "args": ["-y", "your-mcp-package"],
         "env": {
           "YOUR_API_KEY": "${YOUR_API_KEY}"
         }
       }
     }
   }
   ```

2. Run `/sync` to deploy the configuration
3. Restart Claude Desktop for changes to take effect

## Environment Variables

Required environment variables should be set in your shell configuration:

```bash
# ~/.zshrc or ~/.bashrc
export GITHUB_TOKEN="your-github-token"
export CONTEXT7_API_KEY="your-context7-key"
export ELEVENLABS_API_KEY="your-elevenlabs-key"
export NOTION_API_KEY="your-notion-api-key"
```

## Backup and Restore

### Automatic Backups

The `/sync` command automatically creates timestamped backups:

```bash
~/Library/Application Support/Claude/claude_desktop_config.json.backup.YYYYMMDD_HHMMSS
```

### Manual Backup

```bash
# Create manual backup
cp "~/Library/Application Support/Claude/claude_desktop_config.json" \
   "~/Library/Application Support/Claude/claude_desktop_config.json.manual.backup"
```

### Restore from Backup

```bash
# Restore from backup
cp "~/Library/Application Support/Claude/claude_desktop_config.json.backup.YYYYMMDD_HHMMSS" \
   "~/Library/Application Support/Claude/claude_desktop_config.json"
```

## Migration from Legacy Configuration

### Previous Incorrect Assumptions

Earlier versions of this documentation incorrectly referenced `~/.mcp.json` as the primary
configuration location. This file is **NOT** used by Claude Desktop.

### Current State

- **Claude Desktop** reads only from `~/Library/Application Support/Claude/claude_desktop_config.json`
- **Repository `.mcp.json`** serves as the source that gets merged into Claude Desktop config
- **No standalone MCP config** file is used by Claude Desktop

## Troubleshooting

### MCP Servers Not Loading

1. **Check Config Location**:

   ```bash
   ls -la "~/Library/Application Support/Claude/claude_desktop_config.json"
   ```

2. **Validate JSON Syntax**:

   ```bash
   cat "~/Library/Application Support/Claude/claude_desktop_config.json" | jq
   ```

3. **Verify Environment Variables**:

   ```bash
   echo $GITHUB_TOKEN
   echo $CONTEXT7_API_KEY
   echo $ELEVENLABS_API_KEY
   ```

4. **Restart Claude Desktop**: Required after configuration changes

### Configuration File Not Found

If Claude Desktop config file doesn't exist:

```bash
# Create the directory if it doesn't exist
mkdir -p "~/Library/Application Support/Claude"

# Create minimal config file
echo '{"mcpServers": {}}' > "~/Library/Application Support/Claude/claude_desktop_config.json"

# Run sync to populate with MCP servers
/sync
```

### Package Installation Issues

- npx packages are downloaded on first use
- Ensure Node.js is installed: `brew install node`
- Check network connectivity
- Test manually: `npx -y package-name --help`

### Permission Issues

```bash
# Fix permissions if needed
chmod 644 "~/Library/Application Support/Claude/claude_desktop_config.json"
```

## Configuration Validation

### Syntax Check

```bash
# Validate JSON syntax
jq . "~/Library/Application Support/Claude/claude_desktop_config.json"
```

### MCP Server Test

```bash
# Test individual MCP servers
npx -y @modelcontextprotocol/server-filesystem --help
npx -y @modelcontextprotocol/server-github --help
```

## Benefits of Current Architecture

1. **Accurate Location**: Uses the actual Claude Desktop configuration file
2. **Centralized Management**: Repository serves as single reference
3. **Safe Deployment**: Automatic backups prevent configuration loss
4. **Merge Strategy**: Preserves existing Claude Desktop settings
5. **Version Control**: Track MCP changes in repository

---

**Important**: Always restart Claude Desktop after configuration changes for MCP servers to become available.
