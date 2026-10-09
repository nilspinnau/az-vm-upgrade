@{
    Severity = @('Error','Warning')
    IncludeRules = @(
        'PSAvoidUsingInvokeExpression',
        'PSAvoidUsingConvertToSecureStringWithPlainText',
        'PSAvoidUsingPlainTextForPassword',
        'PSAvoidUsingUsernameAndPasswordParams',
        'PSUseDeclaredVarsMoreThanAssignments',
        'PSAvoidAssignmentToAutomaticVariable',
        'PSAvoidUsingEmptyCatchBlock',
        'PSUseCmdletCorrectly'
    )
}
