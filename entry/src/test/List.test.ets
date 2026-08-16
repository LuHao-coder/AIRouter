import localUnitTest from './LocalUnit.test';
import connectionModelTest from './ConnectionModel.test';
import connectionRepositoryTest from './ConnectionRepository.test';
import gatewayClientTest from './GatewayClient.test';

export default function testsuite() {
  localUnitTest();
  connectionModelTest();
  connectionRepositoryTest();
  gatewayClientTest();
}
