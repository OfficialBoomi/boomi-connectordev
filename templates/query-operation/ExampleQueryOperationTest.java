package com.example.connector;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;

import java.net.InetSocketAddress;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import com.boomi.connector.api.Operation;
import com.boomi.connector.api.OperationContext;
import com.boomi.connector.api.OperationStatus;
import com.boomi.connector.api.OperationType;
import com.boomi.connector.api.QueryFilter;
import com.boomi.connector.api.Sort;
import com.boomi.connector.testutil.ConnectorTester;
import com.boomi.connector.testutil.QueryFilterBuilder;
import com.boomi.connector.testutil.QueryGroupingBuilder;
import com.boomi.connector.testutil.QuerySimpleBuilder;
import com.boomi.connector.testutil.SimpleOperationResult;
import com.boomi.connector.util.BaseConnector;
import com.sun.net.httpserver.HttpServer;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;

public class ExampleQueryOperationTest {

    private HttpServer _server;
    private volatile String _lastQuery;
    private ConnectorTester _tester;

    @Before
    public void setUp() throws Exception {
        _server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        _server.createContext("/", exchange -> {
            String rawQuery = exchange.getRequestURI().getRawQuery();
            _lastQuery = rawQuery == null ? "" : URLDecoder.decode(rawQuery, "UTF-8");
            byte[] body = "[{\"id\":1},{\"id\":2}]".getBytes(StandardCharsets.UTF_8);
            exchange.sendResponseHeaders(200, body.length);
            exchange.getResponseBody().write(body);
            exchange.close();
        });
        _server.start();

        Map<String, Object> connProps = new HashMap<>();
        connProps.put("baseUrl", "http://127.0.0.1:" + _server.getAddress().getPort());
        _tester = new ConnectorTester(new BaseConnector() {
            @Override
            protected Operation createQueryOperation(OperationContext context) {
                return new ExampleQueryOperation(context);
            }
        });
        _tester.setOperationContext(OperationType.QUERY, connProps, new HashMap<>(), "Ticket", null);
    }

    @After
    public void tearDown() {
        _server.stop(0);
    }

    @Test
    public void translatesNestedFilterAndSort() {
        QueryFilter filter = new QueryFilterBuilder(
                QueryGroupingBuilder.and(
                        new QuerySimpleBuilder("status", "eq", "open"),
                        QueryGroupingBuilder.or(
                                new QuerySimpleBuilder("priority", "eq", "high"),
                                new QuerySimpleBuilder("created", "between", "2026-01-01", "2026-06-30"))))
                .toFilter()
                .withSort(new Sort().withProperty("created").withSortOrder("asc"));

        List<SimpleOperationResult> results = _tester.executeQueryOperation(filter);

        assertEquals(OperationStatus.SUCCESS, results.get(0).getStatus());
        assertEquals(2, results.get(0).getPayloads().size());
        assertEquals("filter=(status eq 'open' and (priority eq 'high' or "
                + "(created ge '2026-01-01' and created le '2026-06-30')))&orderBy=created asc", _lastQuery);
    }

    @Test
    public void rejectsUndeclaredOperator() {
        QueryFilter filter = new QueryFilterBuilder(new QuerySimpleBuilder("status", "like", "x")).toFilter();

        List<SimpleOperationResult> results = _tester.executeQueryOperation(filter);

        assertEquals(OperationStatus.APPLICATION_ERROR, results.get(0).getStatus());
        assertNull(_lastQuery);
    }
}
