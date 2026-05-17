defmodule SymphonyElixir.GitHubProjects.Client do
  @moduledoc """
  Thin GitHub GraphQL client for polling GitHub Projects v2 items.
  """

  require Logger
  alias SymphonyElixir.{Config, Linear.Issue}

  @item_page_size 50
  @field_page_size 50
  @max_error_body_log_bytes 1_000

  @project_items_query """
  query SymphonyGitHubProjectItems($owner: String!, $number: Int!, $first: Int!, $fieldFirst: Int!, $after: String) {
    organization(login: $owner) {
      projectV2(number: $number) {
        id
        items(first: $first, after: $after) {
          nodes {
            id
            content {
              ... on Issue {
                id
                number
                title
                body
                url
                state
                createdAt
                updatedAt
                repository {
                  nameWithOwner
                }
                assignees(first: 10) {
                  nodes {
                    login
                  }
                }
                labels(first: 20) {
                  nodes {
                    name
                  }
                }
              }
            }
            fieldValues(first: $fieldFirst) {
              nodes {
                ... on ProjectV2ItemFieldSingleSelectValue {
                  name
                  field {
                    ... on ProjectV2FieldCommon {
                      name
                    }
                  }
                }
              }
            }
          }
          pageInfo {
            hasNextPage
            endCursor
          }
        }
      }
    }
    user(login: $owner) {
      projectV2(number: $number) {
        id
        items(first: $first, after: $after) {
          nodes {
            id
            content {
              ... on Issue {
                id
                number
                title
                body
                url
                state
                createdAt
                updatedAt
                repository {
                  nameWithOwner
                }
                assignees(first: 10) {
                  nodes {
                    login
                  }
                }
                labels(first: 20) {
                  nodes {
                    name
                  }
                }
              }
            }
            fieldValues(first: $fieldFirst) {
              nodes {
                ... on ProjectV2ItemFieldSingleSelectValue {
                  name
                  field {
                    ... on ProjectV2FieldCommon {
                      name
                    }
                  }
                }
              }
            }
          }
          pageInfo {
            hasNextPage
            endCursor
          }
        }
      }
    }
  }
  """

  @issues_by_ids_query """
  query SymphonyGitHubIssuesById($ids: [ID!]!, $fieldFirst: Int!) {
    nodes(ids: $ids) {
      ... on Issue {
        id
        number
        title
        body
        url
        state
        createdAt
        updatedAt
        repository {
          nameWithOwner
        }
        assignees(first: 10) {
          nodes {
            login
          }
        }
        labels(first: 20) {
          nodes {
            name
          }
        }
        projectItems(first: 20) {
          nodes {
            id
            project {
              number
            }
            fieldValues(first: $fieldFirst) {
              nodes {
                ... on ProjectV2ItemFieldSingleSelectValue {
                  name
                  field {
                    ... on ProjectV2FieldCommon {
                      name
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
  """

  @project_fields_query """
  query SymphonyGitHubProjectFields($owner: String!, $number: Int!, $first: Int!) {
    organization(login: $owner) {
      projectV2(number: $number) {
        id
        fields(first: $first) {
          nodes {
            ... on ProjectV2SingleSelectField {
              id
              name
              options {
                id
                name
              }
            }
          }
        }
      }
    }
    user(login: $owner) {
      projectV2(number: $number) {
        id
        fields(first: $first) {
          nodes {
            ... on ProjectV2SingleSelectField {
              id
              name
              options {
                id
                name
              }
            }
          }
        }
      }
    }
  }
  """

  @add_comment_mutation """
  mutation SymphonyGitHubAddComment($subjectId: ID!, $body: String!) {
    addComment(input: {subjectId: $subjectId, body: $body}) {
      commentEdge {
        node {
          id
        }
      }
    }
  }
  """

  @update_item_field_mutation """
  mutation SymphonyGitHubUpdateProjectItemStatus($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
    updateProjectV2ItemFieldValue(input: {
      projectId: $projectId,
      itemId: $itemId,
      fieldId: $fieldId,
      value: {singleSelectOptionId: $optionId}
    }) {
      projectV2Item {
        id
      }
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker

    cond do
      is_nil(tracker.api_key) ->
        {:error, :missing_github_api_token}

      is_nil(tracker.project_owner) ->
        {:error, :missing_github_project_owner}

      is_nil(tracker.project_number) ->
        {:error, :missing_github_project_number}

      true ->
        with {:ok, assignee_filter} <- routing_assignee_filter() do
          do_fetch_project_items(tracker.project_owner, tracker.project_number, tracker.active_states, assignee_filter)
        end
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized_states = Enum.map(state_names, &to_string/1) |> Enum.uniq()

    if normalized_states == [] do
      {:ok, []}
    else
      tracker = Config.settings!().tracker
      do_fetch_project_items(tracker.project_owner, tracker.project_number, normalized_states, nil)
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        with {:ok, assignee_filter} <- routing_assignee_filter(),
             {:ok, body} <- graphql(@issues_by_ids_query, %{ids: ids, fieldFirst: @field_page_size}),
             {:ok, issues} <- decode_issues_by_id_response(body, assignee_filter) do
          {:ok, sort_issues_by_requested_ids(issues, issue_order_index(ids))}
        end
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, response} <- graphql(@add_comment_mutation, %{subjectId: issue_id, body: body}),
         comment_id when is_binary(comment_id) <- get_in(response, ["data", "addComment", "commentEdge", "node", "id"]) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, project_id, field_id, option_id} <- resolve_status_option(state_name),
         {:ok, item_id} <- resolve_project_item_id(issue_id),
         {:ok, response} <-
           graphql(@update_item_field_mutation, %{
             projectId: project_id,
             itemId: item_id,
             fieldId: field_id,
             optionId: option_id
           }),
         updated_item_id when is_binary(updated_item_id) <-
           get_in(response, ["data", "updateProjectV2ItemFieldValue", "projectV2Item", "id"]) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  @spec graphql(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def graphql(query, variables \\ %{}, opts \\ [])
      when is_binary(query) and is_map(variables) and is_list(opts) do
    payload = build_graphql_payload(query, variables, Keyword.get(opts, :operation_name))
    request_fun = Keyword.get(opts, :request_fun, &post_graphql_request/2)

    with {:ok, headers} <- graphql_headers(),
         {:ok, %{status: 200, body: body}} <- request_fun.(payload, headers) do
      case body do
        %{"errors" => errors} -> {:error, {:github_graphql_errors, errors}}
        _ -> {:ok, body}
      end
    else
      {:ok, response} ->
        Logger.error(
          "GitHub GraphQL request failed status=#{response.status}" <>
            github_error_context(payload, response)
        )

        {:error, {:github_api_status, response.status}}

      {:error, reason} ->
        Logger.error("GitHub GraphQL request failed: #{inspect(reason)}")
        {:error, {:github_api_request, reason}}
    end
  end

  @doc false
  @spec normalize_project_item_for_test(map()) :: Issue.t() | nil
  def normalize_project_item_for_test(project_item) when is_map(project_item) do
    normalize_project_item(project_item, nil)
  end

  @doc false
  @spec normalize_issue_for_test(map(), map() | nil) :: Issue.t() | nil
  def normalize_issue_for_test(issue, project_item \\ nil) when is_map(issue) do
    normalize_issue(issue, project_item, nil)
  end

  defp do_fetch_project_items(project_owner, project_number, state_names, assignee_filter) do
    do_fetch_project_items_page(project_owner, project_number, state_names, assignee_filter, nil, [])
  end

  defp do_fetch_project_items_page(project_owner, project_number, state_names, assignee_filter, after_cursor, acc_issues) do
    with {:ok, body} <-
           graphql(@project_items_query, %{
             owner: project_owner,
             number: project_number,
             first: @item_page_size,
             fieldFirst: @field_page_size,
             after: after_cursor
           }),
         {:ok, issues, page_info} <- decode_project_items_page(body, state_names, assignee_filter) do
      updated_acc = prepend_page_issues(issues, acc_issues)

      case next_page_cursor(page_info) do
        {:ok, next_cursor} ->
          do_fetch_project_items_page(
            project_owner,
            project_number,
            state_names,
            assignee_filter,
            next_cursor,
            updated_acc
          )

        :done ->
          {:ok, finalize_paginated_issues(updated_acc)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp decode_project_items_page(body, state_names, assignee_filter) do
    with {:ok, project} <- project_from_owner_response(body),
         %{"items" => %{"nodes" => nodes, "pageInfo" => page_info}} <- project,
         {:ok, issues} <- decode_project_item_nodes(nodes, state_names, assignee_filter) do
      {:ok, issues, %{has_next_page: page_info["hasNextPage"] == true, end_cursor: page_info["endCursor"]}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :github_unknown_payload}
    end
  end

  defp decode_project_item_nodes(nodes, state_names, assignee_filter) when is_list(nodes) do
    wanted_states = MapSet.new(Enum.map(state_names, &normalize_state/1))

    issues =
      nodes
      |> Enum.map(&normalize_project_item(&1, assignee_filter))
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(fn %Issue{state: state} -> MapSet.member?(wanted_states, normalize_state(state)) end)

    {:ok, issues}
  end

  defp decode_project_item_nodes(_nodes, _state_names, _assignee_filter), do: {:error, :github_unknown_payload}

  defp decode_issues_by_id_response(%{"data" => %{"nodes" => nodes}}, assignee_filter) when is_list(nodes) do
    tracker = Config.settings!().tracker

    issues =
      nodes
      |> Enum.map(&normalize_issue_with_configured_project(&1, tracker.project_number, assignee_filter))
      |> Enum.reject(&is_nil/1)

    {:ok, issues}
  end

  defp decode_issues_by_id_response(_body, _assignee_filter), do: {:error, :github_unknown_payload}

  defp normalize_issue_with_configured_project(issue, project_number, assignee_filter) when is_map(issue) do
    project_item = find_project_item(issue, project_number)
    normalize_issue(issue, project_item, assignee_filter)
  end

  defp normalize_issue_with_configured_project(_issue, _project_number, _assignee_filter), do: nil

  defp normalize_project_item(%{"content" => content} = project_item, assignee_filter) when is_map(content) do
    normalize_issue(content, project_item, assignee_filter)
  end

  defp normalize_project_item(_project_item, _assignee_filter), do: nil

  defp normalize_issue(issue, project_item, assignee_filter) when is_map(issue) do
    repository = get_in(issue, ["repository", "nameWithOwner"])
    issue_number = issue["number"]

    %Issue{
      id: issue["id"],
      identifier: github_identifier(repository, issue_number),
      title: issue["title"],
      description: issue["body"],
      priority: nil,
      state: status_field_value(project_item) || issue["state"],
      branch_name: nil,
      url: issue["url"],
      assignee_id: first_assignee_login(issue),
      project_item_id: project_item_id(project_item),
      blocked_by: [],
      labels: extract_labels(issue),
      assigned_to_worker: assigned_to_worker?(issue, assignee_filter),
      created_at: parse_datetime(issue["createdAt"]),
      updated_at: parse_datetime(issue["updatedAt"])
    }
  end

  defp resolve_status_option(state_name) do
    tracker = Config.settings!().tracker

    with {:ok, body} <-
           graphql(@project_fields_query, %{
             owner: tracker.project_owner,
             number: tracker.project_number,
             first: @field_page_size
           }),
         {:ok, project} <- project_from_owner_response(body),
         %{"id" => project_id, "fields" => %{"nodes" => fields}} <- project,
         %{"id" => field_id, "options" => options} <- find_status_field(fields),
         %{"id" => option_id} <- find_option(options, state_name) do
      {:ok, project_id, field_id, option_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :status_option_not_found}
    end
  end

  defp resolve_project_item_id(issue_id) do
    with {:ok, [issue | _]} <- fetch_issue_states_by_ids([issue_id]),
         item_id when is_binary(item_id) <- issue.project_item_id do
      {:ok, item_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :project_item_not_found}
    end
  end

  defp project_from_owner_response(%{"data" => data}) when is_map(data) do
    project =
      data
      |> Map.get("organization")
      |> project_from_owner()
      |> case do
        nil -> data |> Map.get("user") |> project_from_owner()
        project -> project
      end

    case project do
      %{} -> {:ok, project}
      _ -> {:error, :github_project_not_found}
    end
  end

  defp project_from_owner_response(_body), do: {:error, :github_unknown_payload}

  defp project_from_owner(%{"projectV2" => project}) when is_map(project), do: project
  defp project_from_owner(_owner), do: nil

  defp find_project_item(%{"projectItems" => %{"nodes" => nodes}}, project_number) when is_list(nodes) do
    Enum.find(nodes, fn item -> get_in(item, ["project", "number"]) == project_number end)
  end

  defp find_project_item(_issue, _project_number), do: nil

  defp find_status_field(fields) when is_list(fields) do
    Enum.find(fields, fn
      %{"name" => name, "options" => options} when is_binary(name) and is_list(options) ->
        normalize_state(name) == "status"

      _ ->
        false
    end)
  end

  defp find_status_field(_fields), do: nil

  defp find_option(options, state_name) when is_list(options) do
    normalized_state = normalize_state(state_name)

    Enum.find(options, fn
      %{"name" => name} when is_binary(name) -> normalize_state(name) == normalized_state
      _ -> false
    end)
  end

  defp find_option(_options, _state_name), do: nil

  defp status_field_value(%{"fieldValues" => %{"nodes" => nodes}}) when is_list(nodes) do
    nodes
    |> Enum.find_value(fn
      %{"name" => value, "field" => %{"name" => field_name}} when is_binary(value) and is_binary(field_name) ->
        if normalize_state(field_name) == "status", do: value

      _ ->
        nil
    end)
  end

  defp status_field_value(_project_item), do: nil

  defp github_identifier(repository, issue_number) when is_binary(repository) and is_integer(issue_number) do
    "#{repository}##{issue_number}"
  end

  defp github_identifier(_repository, issue_number) when is_integer(issue_number), do: "GH-#{issue_number}"
  defp github_identifier(_repository, _issue_number), do: nil

  defp project_item_id(%{"id" => id}) when is_binary(id), do: id
  defp project_item_id(_project_item), do: nil

  defp first_assignee_login(%{"assignees" => %{"nodes" => [%{"login" => login} | _]}}) when is_binary(login), do: login
  defp first_assignee_login(_issue), do: nil

  defp assigned_to_worker?(_issue, nil), do: true

  defp assigned_to_worker?(%{"assignees" => %{"nodes" => assignees}}, %{match_values: match_values})
       when is_list(assignees) and is_struct(match_values, MapSet) do
    assignees
    |> Enum.map(&normalize_assignee_match_value(&1["login"]))
    |> Enum.reject(&is_nil/1)
    |> Enum.any?(&MapSet.member?(match_values, &1))
  end

  defp assigned_to_worker?(_issue, _assignee_filter), do: false

  defp routing_assignee_filter do
    case Config.settings!().tracker.assignee do
      nil ->
        {:ok, nil}

      assignee ->
        case normalize_assignee_match_value(assignee) do
          nil -> {:ok, nil}
          normalized -> {:ok, %{configured_assignee: assignee, match_values: MapSet.new([normalized])}}
        end
    end
  end

  defp normalize_assignee_match_value(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_assignee_match_value(_value), do: nil

  defp extract_labels(%{"labels" => %{"nodes" => labels}}) when is_list(labels) do
    labels
    |> Enum.map(& &1["name"])
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.downcase/1)
  end

  defp extract_labels(_), do: []

  defp prepend_page_issues(issues, acc_issues) when is_list(issues) and is_list(acc_issues) do
    Enum.reverse(issues, acc_issues)
  end

  defp finalize_paginated_issues(acc_issues) when is_list(acc_issues), do: Enum.reverse(acc_issues)

  defp next_page_cursor(%{has_next_page: true, end_cursor: end_cursor})
       when is_binary(end_cursor) and byte_size(end_cursor) > 0 do
    {:ok, end_cursor}
  end

  defp next_page_cursor(%{has_next_page: true}), do: {:error, :github_missing_end_cursor}
  defp next_page_cursor(_), do: :done

  defp issue_order_index(ids) when is_list(ids) do
    ids
    |> Enum.with_index()
    |> Map.new()
  end

  defp sort_issues_by_requested_ids(issues, issue_order_index)
       when is_list(issues) and is_map(issue_order_index) do
    fallback_index = map_size(issue_order_index)

    Enum.sort_by(issues, fn
      %Issue{id: issue_id} -> Map.get(issue_order_index, issue_id, fallback_index)
      _ -> fallback_index
    end)
  end

  defp build_graphql_payload(query, variables, operation_name) do
    %{
      "query" => query,
      "variables" => variables
    }
    |> maybe_put_operation_name(operation_name)
  end

  defp maybe_put_operation_name(payload, operation_name) when is_binary(operation_name) do
    trimmed = String.trim(operation_name)

    if trimmed == "" do
      payload
    else
      Map.put(payload, "operationName", trimmed)
    end
  end

  defp maybe_put_operation_name(payload, _operation_name), do: payload

  defp graphql_headers do
    case Config.settings!().tracker.api_key do
      nil ->
        {:error, :missing_github_api_token}

      token ->
        {:ok,
         [
           {"Authorization", "Bearer #{token}"},
           {"Content-Type", "application/json"},
           {"Accept", "application/vnd.github+json"}
         ]}
    end
  end

  defp post_graphql_request(payload, headers) do
    Req.post(Config.settings!().tracker.endpoint,
      headers: headers,
      json: payload,
      connect_options: [timeout: 30_000]
    )
  end

  defp github_error_context(payload, response) when is_map(payload) do
    operation_name =
      case Map.get(payload, "operationName") do
        name when is_binary(name) and name != "" -> " operation=#{name}"
        _ -> ""
      end

    body =
      response
      |> Map.get(:body)
      |> summarize_error_body()

    operation_name <> " body=" <> body
  end

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state), do: ""
end
