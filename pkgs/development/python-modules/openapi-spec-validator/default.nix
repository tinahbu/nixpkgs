{ lib, buildPythonPackage, isPy27, fetchPypi
, jsonschema, pyyaml, six, pathlib
, mock, pytest, pytestcov, pytest-flake8, tox, setuptools }:

buildPythonPackage rec {
  pname = "openapi-spec-validator";
  version = "0.2.9";

  src = fetchPypi {
    inherit pname version;
    sha256 = "79381a69b33423ee400ae1624a461dae7725e450e2e306e32f2dd8d16a4d85cb";
  };

  propagatedBuildInputs = [ jsonschema pyyaml six setuptools ]
    ++ (lib.optionals (isPy27) [ pathlib ]);

  checkInputs = [ mock pytest pytestcov pytest-flake8 tox ];

  meta = with lib; {
    homepage = "https://github.com/p1c2u/openapi-spec-validator";
    description = "Validates OpenAPI Specs against the OpenAPI 2.0 (aka Swagger) and OpenAPI 3.0.0 specification";
    license = licenses.asl20;
    maintainers = with maintainers; [ rvl ];
  };
}
