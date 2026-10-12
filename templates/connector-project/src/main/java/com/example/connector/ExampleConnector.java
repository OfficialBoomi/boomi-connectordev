package com.example.connector;

import com.boomi.connector.api.Operation;
import com.boomi.connector.api.OperationContext;
import com.boomi.connector.util.BaseConnector;

public class ExampleConnector extends BaseConnector {

    @Override
    protected Operation createExecuteOperation(OperationContext context) {
        return new ExampleExecuteOperation(context);
    }
}
