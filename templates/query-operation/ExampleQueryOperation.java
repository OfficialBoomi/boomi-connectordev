package com.example.connector;

import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URI;
import java.net.URLEncoder;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.logging.Level;

import com.boomi.connector.api.Expression;
import com.boomi.connector.api.FilterData;
import com.boomi.connector.api.GroupingExpression;
import com.boomi.connector.api.OperationContext;
import com.boomi.connector.api.OperationResponse;
import com.boomi.connector.api.OperationStatus;
import com.boomi.connector.api.Payload;
import com.boomi.connector.api.QueryFilter;
import com.boomi.connector.api.QueryRequest;
import com.boomi.connector.api.SimpleExpression;
import com.boomi.connector.api.Sort;
import com.boomi.connector.util.BaseQueryOperation;
import com.boomi.connector.util.PayloadUtil;
import com.boomi.connector.util.ResponseUtil;
import com.boomi.util.IOUtil;
import com.boomi.util.json.splitter.JsonRootArraySplitter;
import com.boomi.util.json.splitter.JsonSplitter;

/**
 * Needs boomi-json-util and Jackson bundled (references/build_and_package.md, Dependency rules).
 * Pairs with:
 * <pre>
 * &lt;operation types="QUERY" supportsBrowse="true"&gt;
 *     &lt;queryFilter sorting="one" grouping="any"&gt;
 *         &lt;operator id="eq" label="Equals"/&gt;
 *         &lt;operator id="between" label="Between" numArguments="2"/&gt;
 *         &lt;sortOrder id="asc" label="Ascending"/&gt;
 *         &lt;sortOrder id="desc" label="Descending"/&gt;
 *     &lt;/queryFilter&gt;
 *     &lt;browseConfiguration/&gt;
 * &lt;/operation&gt;
 * </pre>
 */
public class ExampleQueryOperation extends BaseQueryOperation {

    private static final int CONNECT_TIMEOUT_MS = 30000;
    private static final int READ_TIMEOUT_MS = 60000;

    private final String _baseUrl;
    private final String _objectType;

    public ExampleQueryOperation(OperationContext context) {
        super(context);
        _baseUrl = context.getConnectionProperties().getProperty("baseUrl");
        _objectType = context.getObjectTypeId();
    }

    @Override
    protected void executeQuery(QueryRequest request, OperationResponse response) {
        FilterData input = request.getFilter();
        InputStream outputData = null;
        JsonSplitter splitter = null;
        try {
            String url = buildUrl(input.getFilter());
            HttpURLConnection connection = (HttpURLConnection) URI.create(url).toURL().openConnection();
            connection.setConnectTimeout(CONNECT_TIMEOUT_MS);
            connection.setReadTimeout(READ_TIMEOUT_MS);
            int code = connection.getResponseCode();
            String message = connection.getResponseMessage();
            outputData = code >= 400 ? connection.getErrorStream() : connection.getInputStream();
            if (outputData == null) {
                ResponseUtil.addPartialResultWithHttpStatus(response, input, code, message);
            } else if (code >= 400) {
                ResponseUtil.addPartialResultWithHttpStatus(response, input, code, message,
                        PayloadUtil.toPayload(outputData));
            } else {
                // one document per record, streamed as read
                splitter = new JsonRootArraySplitter(outputData);
                for (Payload payload : splitter) {
                    response.addPartialResult(input, OperationStatus.SUCCESS, String.valueOf(code), message, payload);
                }
            }
        } catch (UnsupportedQueryException e) {
            response.addPartialResult(input, OperationStatus.APPLICATION_ERROR, "-1", e.getMessage(), null);
        } catch (Exception e) {
            response.getLogger().log(Level.SEVERE, "query failed", e);
            response.addPartialResult(input, OperationStatus.FAILURE, "-1", e.getMessage(), null);
        } finally {
            IOUtil.closeQuietly(outputData, splitter);
        }
        response.finishPartialResult(input);
    }

    private String buildUrl(QueryFilter filter) throws Exception {
        StringBuilder url = new StringBuilder(_baseUrl).append('/').append(_objectType);
        List<String> params = new ArrayList<>();
        Expression root = filter == null ? null : filter.getExpression();
        if (root != null) {
            params.add("filter=" + URLEncoder.encode(toClause(root), "UTF-8"));
        }
        if (filter != null && !filter.getSort().isEmpty()) {
            if (filter.getSort().size() > 1) {
                throw new UnsupportedQueryException("Only one sort is supported");
            }
            Sort sort = filter.getSort().get(0);
            if (!"asc".equals(sort.getSortOrder()) && !"desc".equals(sort.getSortOrder())) {
                throw new UnsupportedQueryException("Unsupported sort order: " + sort.getSortOrder());
            }
            params.add("orderBy=" + URLEncoder.encode(sort.getProperty() + " " + sort.getSortOrder(), "UTF-8"));
        }
        if (!params.isEmpty()) {
            url.append('?').append(String.join("&", params));
        }
        return url.toString();
    }

    private static String toClause(Expression expr) {
        if (expr instanceof SimpleExpression) {
            SimpleExpression simple = (SimpleExpression) expr;
            List<String> args = simple.getArguments();
            if ("eq".equals(simple.getOperator()) && args.size() == 1) {
                return simple.getProperty() + " eq " + literal(args.get(0));
            }
            if ("between".equals(simple.getOperator()) && args.size() == 2) {
                return "(" + simple.getProperty() + " ge " + literal(args.get(0)) + " and "
                        + simple.getProperty() + " le " + literal(args.get(1)) + ")";
            }
            throw new UnsupportedQueryException("Unsupported operator: " + simple.getOperator());
        }
        if (!(expr instanceof GroupingExpression)) {
            throw new UnsupportedQueryException("Unsupported expression: " + expr);
        }
        GroupingExpression group = (GroupingExpression) expr;
        List<String> clauses = new ArrayList<>();
        for (Expression nested : group.getNestedExpressions()) {
            clauses.add(toClause(nested));
        }
        return "(" + String.join(" " + group.getOperator().value().toLowerCase(Locale.ROOT) + " ", clauses) + ")";
    }

    private static String literal(String value) {
        return "'" + value.replace("'", "''") + "'";
    }

    private static final class UnsupportedQueryException extends RuntimeException {
        UnsupportedQueryException(String message) {
            super(message);
        }
    }
}
