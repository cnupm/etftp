{application, etftp_app,
[
    {description, "Simple TFTP server"},
    {vsn, "1"},
    {mod, {etftp_app,[]}},
    {modules, [etftp, etftp_app]},
    {registered, []},
    {applications, [kernel, stdlib, sasl]},
    {env, [{timeout, 15000}, {port, 7777}]}
]}.