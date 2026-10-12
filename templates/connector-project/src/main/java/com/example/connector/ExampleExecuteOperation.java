package com.example.connector;

import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URI;
import java.util.logging.Level;

import com.boomi.connector.api.ObjectData;
import com.boomi.connector.api.OperationContext;
import com.boomi.connector.api.OperationResponse;
import com.boomi.connector.api.OperationStatus;
import com.boomi.connector.api.UpdateRequest;
import com.boomi.connector.util.BaseUpdateOperation;
import com.boomi.connector.util.PayloadUtil;
import com.boomi.util.IOUtil;

public class ExampleExecuteOperation extends BaseUpdateOperation {

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
                int code = connection.getResponseCode();
                outputData = connection.getInputStream();
                // the payload reads the response stream as the platform consumes it; never buffer it first
                response.addResult(input, OperationStatus.SUCCESS, String.valueOf(code), "OK",
                        PayloadUtil.toPayload(outputData));
            } catch (Exception e) {
                input.getLogger().log(Level.SEVERE, "unable to process input", e);
                response.addResult(input, OperationStatus.APPLICATION_ERROR, "-1", e.getMessage(), null);
            } finally {
                IOUtil.closeQuietly(inputData, outputData);
            }
        }
    }
}
