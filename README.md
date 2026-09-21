# Operata MCP recipes

Working integrations that connect the [Operata MCP server](https://docs.operata.com/docs/guides-mcp-intro) to an AI platform. Each recipe is a self-contained directory you can fork, configure, and run against your own accounts. They are for engineers evaluating what the integration does before deciding how to build on it.

Every recipe follows the same shape: copy `config.env.example` to `config.env`, set your values, run the scripts in order, and run the teardown script when you're done.

## Recipes

| Recipe | What it does | Guide |
| --- | --- | --- |
| [bedrock-agentcore](bedrock-agentcore/) | Exposes the Operata MCP tools to Amazon Bedrock through an AgentCore Gateway, and hands a voice quality incident to Claude for diagnosis from a Lambda. | [Diagnose voice incidents with Amazon Bedrock](https://docs.operata.com/docs/guides-mcp-bedrock-agentcore) |

## Before you start

You need an Operata API key from **Group Settings → API Management → Create New Key** in the Operata console. This is not the REST token under Settings → Config → API; the MCP endpoint rejects that one.

Your key is fixed to the Operata group it was created in, and to the environment it came from. Keys minted at `app.operata.io` work against `https://api.operata.io/v1/mcp`; keys from `app-dev.operata.io` work against `https://api-dev.operata.io/v1/mcp`.

Each recipe lists its own tooling and cloud prerequisites.

## Credentials

`config.env` is gitignored in every recipe. No recipe writes your key into a deployment package, a log, or any file it commits. Where a recipe can hand the credential to a managed secret store instead of holding it, it does.

## Support

Issues and pull requests are welcome. For questions about the Operata MCP server itself, see the [MCP documentation](https://docs.operata.com/docs/guides-mcp-intro) or contact Operata support.

## License

Apache 2.0. See [LICENSE](LICENSE).
