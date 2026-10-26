package com.example.connector;

import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URI;

import com.boomi.connector.api.ObjectData;
import com.boomi.connector.api.OperationContext;
import com.boomi.connector.api.OperationResponse;
import com.boomi.connector.api.UpdateRequest;
import com.boomi.connector.util.BaseUpdateOperation;
import com.boomi.connector.util.PayloadUtil;
import com.boomi.connector.util.ResponseUtil;
import com.boomi.util.IOUtil;

public class ExampleExecuteOperation extends BaseUpdateOperation {

    private static final int CONNECT_TIMEOUT_MS = 30000;
    private static final int READ_TIMEOUT_MS = 60000;

    private final String _baseUrl;

    public ExampleExecuteOperation(OperationContext context) {
        super(context);
        _baseUrl = context.getConnectionProperties().getProperty("baseUrl");
    }

    @Override
    protected void executeUpdate(UpdateRequest request, OperationResponse response) {
        for (ObjectData input : request) {
            InputStream inputData = input.getData();
            InputStream outputData = null;
            try {
                HttpURLConnection connection = (HttpURLConnection) URI.create(_baseUrl).toURL().openConnection();
                connection.setConnectTimeout(CONNECT_TIMEOUT_MS);
                connection.setReadTimeout(READ_TIMEOUT_MS);
                int code = connection.getResponseCode();
                outputData = code >= 400 ? connection.getErrorStream() : connection.getInputStream();
                if (outputData == null) {
                    ResponseUtil.addEmptyResultWithHttpStatus(response, input, code, connection.getResponseMessage());
                } else {
                    // the payload reads the response stream as the platform consumes it; never buffer it first
                    ResponseUtil.addResultWithHttpStatus(response, input, code, connection.getResponseMessage(),
                            PayloadUtil.toPayload(outputData));
                }
            } catch (Exception e) {
                ResponseUtil.addExceptionFailure(response, input, e);
            } finally {
                IOUtil.closeQuietly(inputData, outputData);
            }
        }
    }
}
